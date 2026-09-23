import { describe, expect, test } from "vitest"
import { Effect, Layer } from "effect"
import * as dispatcher from "../src/handlers/dispatcher.ts"
import * as router from "../src/handlers/router.ts"
import { KeepClient, KeepError } from "../src/lib/keep-client.ts"
import { encodePipelineMessage, type PipelineMessage } from "../src/lib/schema.ts"
import { alert, makeMemoryJournal, makeMemoryNotifier, makeMemoryQueue, withEnv } from "./helpers.ts"

const message = (overrides: Partial<PipelineMessage> = {}): PipelineMessage => ({
  transitionId: "t-1",
  source: "prod",
  fingerprint: "prod:a1b2c3d4e5f60708",
  status: "firing",
  severity: "critical",
  receivedAt: "2026-09-23T00:00:01Z",
  receiver: "keep",
  alert: alert(),
  ...overrides,
})

const sqsEvent = (messages: ReadonlyArray<PipelineMessage>) => ({
  Records: messages.map((m, i) => ({ messageId: `m${i + 1}`, body: Effect.runSync(encodePipelineMessage(m)) })),
})

describe("router handler", () => {
  const setup = () => {
    const journal = makeMemoryJournal()
    const queue = makeMemoryQueue()
    const notifier = makeMemoryNotifier()
    const env = withEnv({ CRITICAL_TOPIC_ARN: "arn:topic", KEEP_DELIVERY_QUEUE_URL: "https://sqs/keep-delivery.fifo" })
    const layer = Layer.mergeAll(journal.layer, queue.layer, notifier.layer, env)
    return { queue, notifier, run: (e: unknown) => Effect.runPromise(router.handle(e).pipe(Effect.provide(layer))) }
  }

  test("sends critical alerts directly and forwards every alert to keep-delivery.fifo", async () => {
    const { queue, notifier, run } = setup()
    const result = await run(sqsEvent([message(), message({ transitionId: "t-2", severity: "warning" })]))
    expect(result.batchItemFailures).toEqual([])
    expect(notifier.published).toHaveLength(1)
    expect(notifier.published[0]?.subject).toBe("[FIRING] KubePodCrashLooping (prod)")
    expect(queue.sent.map((m) => m.deduplicationId)).toEqual(["t-1", "t-2"])
  })

  test("fails an undecodable record and the rest of the batch", async () => {
    const { run } = setup()
    const event = sqsEvent([message(), message({ transitionId: "t-2" })])
    event.Records[0] = { messageId: "m1", body: "garbage" }
    const result = await run(event)
    expect(result.batchItemFailures.map((f) => f.itemIdentifier)).toEqual(["m1", "m2"])
  })
})

describe("dispatcher handler", () => {
  const setup = (status: (fingerprint: string) => number) => {
    const journal = makeMemoryJournal()
    const posted: Array<{ fingerprint: string; payload: unknown }> = []
    const keep = Layer.succeed(KeepClient, {
      postAlert: (fingerprint, payload) => {
        const code = status(fingerprint)
        return code === 202
          ? Effect.sync(() => {
              posted.push({ fingerprint, payload })
              return { status: 202, taskName: "task-1" }
            })
          : Effect.fail(new KeepError({ status: code, cause: "unavailable" }))
      },
    })
    const layer = Layer.mergeAll(journal.layer, keep)
    return { journal, posted, run: (e: unknown) => Effect.runPromise(dispatcher.handle(e).pipe(Effect.provide(layer))) }
  }

  test("posts an Alertmanager-shaped payload with the scoped fingerprint and source label", async () => {
    const { posted, run } = setup(() => 202)
    const result = await run(sqsEvent([message()]))
    expect(result.batchItemFailures).toEqual([])
    expect(posted[0]?.fingerprint).toBe("prod:a1b2c3d4e5f60708")
    expect(posted[0]?.payload).toMatchObject({
      version: "4",
      alerts: [{ fingerprint: "prod:a1b2c3d4e5f60708", labels: { alert_source: "prod", alertname: "KubePodCrashLooping" } }],
    })
  })

  test("returns batch item failures when Keep is unavailable so SQS redelivers in order", async () => {
    const { run } = setup((fp) => (fp.endsWith("bad") ? 503 : 202))
    const result = await run(
      sqsEvent([message(), message({ transitionId: "t-2", fingerprint: "prod:bad" }), message({ transitionId: "t-3" })]),
    )
    expect(result.batchItemFailures.map((f) => f.itemIdentifier)).toEqual(["m2", "m3"])
  })
})
