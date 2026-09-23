import { describe, expect, test } from "vitest"
import { Effect, Layer } from "effect"
import * as dispatcher from "../src/handlers/dispatcher.ts"
import * as router from "../src/handlers/router.ts"
import { Journal } from "../src/lib/journal.ts"
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

const INHOUSE = "https://sqs.ap-northeast-1.amazonaws.com/111111111111/alert-pipeline-critical-inhouse.fifo"
const KEEP_DELIVERY = "https://sqs.ap-northeast-1.amazonaws.com/111111111111/alert-pipeline-keep-delivery.fifo"

describe("router handler", () => {
  const setup = (options: { snsFails?: () => boolean } = {}) => {
    const journal = makeMemoryJournal()
    const queue = makeMemoryQueue()
    const notifier = makeMemoryNotifier(options.snsFails)
    const env = withEnv({
      CRITICAL_TOPIC_ARN: "arn:topic",
      INHOUSE_NOTIFIER_QUEUE_URL: INHOUSE,
      KEEP_DELIVERY_QUEUE_URL: KEEP_DELIVERY,
    })
    const layer = Layer.mergeAll(journal.layer, queue.layer, notifier.layer, env)
    const seed = (m: PipelineMessage) =>
      Effect.runSync(
        Effect.flatMap(Journal, (j) =>
          j.putReceived({ ...m, payload: "{}", status: m.status, transitionId: m.transitionId }),
        ).pipe(Effect.provide(journal.layer)),
      )
    return {
      journal,
      queue,
      notifier,
      seed,
      run: (e: unknown) => Effect.runPromise(router.handle(e).pipe(Effect.provide(layer))),
    }
  }

  test("delivers critical alerts to the in-house notifier and SNS, and every alert to keep-delivery.fifo", async () => {
    const { queue, notifier, run } = setup()
    const result = await run(sqsEvent([message(), message({ transitionId: "t-2", severity: "warning" })]))
    expect(result.batchItemFailures).toEqual([])

    const inhouse = queue.sent.filter((m) => m.queueUrl === INHOUSE)
    expect(inhouse).toHaveLength(1)
    expect(inhouse[0]).toMatchObject({ groupId: "prod:a1b2c3d4e5f60708", deduplicationId: "t-1" })
    expect(JSON.parse(inhouse[0]!.body)).toMatchObject({
      schemaVersion: 1,
      transitionId: "t-1",
      source: "prod",
      status: "firing",
      severity: "critical",
      alertname: "KubePodCrashLooping",
      summary: "pod is crash looping",
    })
    expect(JSON.parse(inhouse[0]!.body)).not.toHaveProperty("endsAt")

    expect(notifier.published).toHaveLength(1)
    expect(notifier.published[0]?.subject).toBe("[FIRING] KubePodCrashLooping (prod)")
    expect(notifier.published[0]?.message).toBe(inhouse[0]?.body)

    expect(queue.sent.filter((m) => m.queueUrl === KEEP_DELIVERY).map((m) => m.deduplicationId)).toEqual(["t-1", "t-2"])
  })

  test("on retry only re-sends the channels that failed", async () => {
    let snsDown = true
    const { journal, queue, notifier, seed, run } = setup({ snsFails: () => snsDown })
    seed(message())

    const first = await run(sqsEvent([message()]))
    expect(first.batchItemFailures.map((f) => f.itemIdentifier)).toEqual(["m1"])
    expect(journal.items.get("t-1")?.channels).toEqual(new Set(["inhouse"]))
    expect(queue.sent.filter((m) => m.queueUrl === KEEP_DELIVERY)).toHaveLength(0)

    snsDown = false
    const retry = await run(sqsEvent([message()]))
    expect(retry.batchItemFailures).toEqual([])
    expect(queue.sent.filter((m) => m.queueUrl === INHOUSE)).toHaveLength(1)
    expect(notifier.published).toHaveLength(1)
    expect(journal.items.get("t-1")?.channels).toEqual(new Set(["inhouse", "sns"]))
    expect(queue.sent.filter((m) => m.queueUrl === KEEP_DELIVERY)).toHaveLength(1)
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
