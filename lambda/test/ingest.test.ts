import { describe, expect, test } from "vitest"
import { Effect, Layer } from "effect"
import { handle } from "../src/handlers/ingest.ts"
import { alert, makeMemoryJournal, makeMemoryQueue, webhook, withEnv } from "./helpers.ts"

const event = (body: unknown, source = "prod", authorizedSource = source) => ({
  body: typeof body === "string" ? body : JSON.stringify(body),
  isBase64Encoded: false,
  pathParameters: { source },
  requestContext: { requestId: "req-1", authorizer: { source: authorizedSource, principalId: authorizedSource } },
})

const setup = (failOn?: Parameters<typeof makeMemoryQueue>[0]) => {
  const journal = makeMemoryJournal()
  const queue = makeMemoryQueue(failOn)
  const layer = Layer.mergeAll(journal.layer, queue.layer, withEnv({ ALERTS_QUEUE_URL: "https://sqs/alerts.fifo" }))
  return { journal, queue, run: (e: unknown) => Effect.runPromise(handle(e).pipe(Effect.provide(layer))) }
}

describe("ingest handler", () => {
  test("journals and enqueues each alert with fingerprint group and transition dedup id", async () => {
    const { journal, queue, run } = setup()
    const result = await run(event(webhook([alert(), alert({ fingerprint: "ffff", status: "resolved" })])))
    expect(result.statusCode).toBe(200)
    expect(JSON.parse(result.body)).toMatchObject({ accepted: 2, duplicates: 0 })
    expect(queue.sent).toHaveLength(2)
    expect(queue.sent[0]?.groupId).toBe("prod:a1b2c3d4e5f60708")
    expect([...journal.items.values()].every((i) => i.state === "QUEUED")).toBe(true)
  })

  test("drops re-notifications of an already queued transition", async () => {
    const { queue, run } = setup()
    await run(event(webhook([alert()])))
    const second = await run(event(webhook([alert()])))
    expect(JSON.parse(second.body)).toMatchObject({ accepted: 0, duplicates: 1 })
    expect(queue.sent).toHaveLength(1)
  })

  test("answers 5xx when enqueueing fails, and re-queues on the Alertmanager retry", async () => {
    let fail = true
    const { journal, queue, run } = setup(() => fail)
    const first = await run(event(webhook([alert()])))
    expect(first.statusCode).toBe(500)
    expect([...journal.items.values()][0]?.state).toBe("RECEIVED")

    fail = false
    const retry = await run(event(webhook([alert()])))
    expect(JSON.parse(retry.body)).toMatchObject({ requeued: 1 })
    expect(queue.sent).toHaveLength(1)
  })

  test("rejects malformed payloads with 400", async () => {
    const { run } = setup()
    expect((await run(event("{not json"))).statusCode).toBe(400)
    expect((await run(event({ alerts: [{}] }))).statusCode).toBe(400)
  })

  test("rejects a path source that differs from the authorized source", async () => {
    const { run } = setup()
    expect((await run(event(webhook([alert()]), "management", "prod"))).statusCode).toBe(403)
  })
})
