import { describe, expect, test } from "vitest"
import { Effect } from "effect"
import { processFifoBatch } from "../src/lib/fifo-batch.ts"

const records = ["m1", "m2", "m3", "m4"].map((messageId) => ({ messageId, body: messageId }))

describe("processFifoBatch", () => {
  test("reports no failures when every record succeeds", async () => {
    const seen: string[] = []
    const result = await Effect.runPromise(processFifoBatch(records, (r) => Effect.sync(() => void seen.push(r.messageId))))
    expect(result.batchItemFailures).toEqual([])
    expect(seen).toEqual(["m1", "m2", "m3", "m4"])
  })

  test("fails the failed record and every record after it, and stops processing", async () => {
    const seen: string[] = []
    const result = await Effect.runPromise(
      processFifoBatch(records, (r) =>
        r.messageId === "m2" ? Effect.fail("boom") : Effect.sync(() => void seen.push(r.messageId)),
      ),
    )
    expect(result.batchItemFailures.map((f) => f.itemIdentifier)).toEqual(["m2", "m3", "m4"])
    expect(seen).toEqual(["m1"])
  })

  test("treats defects as failures too", async () => {
    const result = await Effect.runPromise(processFifoBatch(records, () => Effect.die("defect")))
    expect(result.batchItemFailures).toHaveLength(4)
  })
})
