/**
 * Consumes keep-delivery.fifo and pushes each alert to Keep. Concurrency is capped by the event
 * source mapping (maximum_concurrency) so that draining a backlog after a Keep outage cannot
 * exhaust Keep's DB connection pool (keephq/keep#5496).
 */
import { Effect, Layer, Schema } from "effect"
import { Dynamo, SecretsManager } from "../lib/aws.ts"
import { processFifoBatch } from "../lib/fifo-batch.ts"
import { Journal, JournalLive } from "../lib/journal.ts"
import { KeepClient, KeepClientLive } from "../lib/keep-client.ts"
import { decodePipelineMessage, type PipelineMessage, SqsEvent } from "../lib/schema.ts"
import { SecretsLive } from "../lib/secrets.ts"

/** Alertmanager-shaped body understood by Keep's prometheus provider. */
export const keepPayload = (message: PipelineMessage) => ({
  version: "4",
  status: message.status,
  receiver: message.receiver,
  ...(message.externalURL === undefined ? {} : { externalURL: message.externalURL }),
  alerts: [
    {
      ...message.alert,
      fingerprint: message.fingerprint,
      labels: { ...message.alert.labels, alert_source: message.source },
    },
  ],
})

export const handle = (event: unknown) =>
  Effect.gen(function* () {
    const journal = yield* Journal
    const keep = yield* KeepClient
    const { Records } = yield* Schema.decodeUnknown(SqsEvent)(event)

    return yield* processFifoBatch(Records, (record) =>
      Effect.gen(function* () {
        const message = yield* decodePipelineMessage(record.body)
        const accepted = yield* keep.postAlert(message.fingerprint, keepPayload(message))
        yield* journal.advance(message.transitionId, "KEEP_ACCEPTED", {
          keep_accepted_at: new Date().toISOString(),
          ...(accepted.taskName === undefined ? {} : { keep_task_name: accepted.taskName }),
        })
      }),
    )
  })

export const layer = Layer.mergeAll(JournalLive, KeepClientLive).pipe(
  Layer.provide(SecretsLive),
  Layer.provide(Layer.mergeAll(Dynamo.Live, SecretsManager.Live)),
)
