import { Effect } from "effect"
import type { SqsRecord } from "./schema.ts"

export interface BatchResponse {
  readonly batchItemFailures: ReadonlyArray<{ readonly itemIdentifier: string }>
}

/**
 * Processes a FIFO batch in order. On the first failure, that record and every record after it
 * are reported as failed (ReportBatchItemFailures) so that no message overtakes a failed one.
 */
export const processFifoBatch = <E, R>(
  records: ReadonlyArray<SqsRecord>,
  processRecord: (record: SqsRecord) => Effect.Effect<void, E, R>,
): Effect.Effect<BatchResponse, never, R> =>
  Effect.gen(function* () {
    for (const [index, record] of records.entries()) {
      const exit = yield* Effect.exit(processRecord(record))
      if (exit._tag === "Failure") {
        yield* Effect.logError("record failed; failing the rest of the batch", {
          messageId: record.messageId,
          remaining: records.length - index,
        }, exit.cause)
        return { batchItemFailures: records.slice(index).map((r) => ({ itemIdentifier: r.messageId })) }
      }
    }
    return { batchItemFailures: [] }
  })
