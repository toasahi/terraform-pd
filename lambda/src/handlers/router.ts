/**
 * Consumes alerts.fifo. Critical alerts are published directly to the critical SNS topic so that
 * their delivery never depends on Keep; every alert is then forwarded to keep-delivery.fifo.
 */
import { Config, Effect, Layer, Schema } from "effect"
import { Dynamo, Sns, Sqs } from "../lib/aws.ts"
import { processFifoBatch } from "../lib/fifo-batch.ts"
import { Journal, JournalLive } from "../lib/journal.ts"
import { Notifier, NotifierLive } from "../lib/notifier.ts"
import { Queue, QueueLive } from "../lib/queue.ts"
import { decodePipelineMessage, type PipelineMessage, SqsEvent } from "../lib/schema.ts"

export const criticalSubject = (message: PipelineMessage) =>
  `[${message.status.toUpperCase()}] ${message.alert.labels.alertname ?? "alert"} (${message.source})`

export const handle = (event: unknown) =>
  Effect.gen(function* () {
    const topicArn = yield* Config.string("CRITICAL_TOPIC_ARN")
    const deliveryQueueUrl = yield* Config.string("KEEP_DELIVERY_QUEUE_URL")
    const criticalSeverities = yield* Config.array(Config.string(), "CRITICAL_SEVERITIES").pipe(
      Config.withDefault<ReadonlyArray<string>>(["critical"]),
    )
    const journal = yield* Journal
    const queue = yield* Queue
    const notifier = yield* Notifier

    const { Records } = yield* Schema.decodeUnknown(SqsEvent)(event)
    return yield* processFifoBatch(Records, (record) =>
      Effect.gen(function* () {
        const message = yield* decodePipelineMessage(record.body)
        if (criticalSeverities.includes(message.severity)) {
          yield* notifier.publish(topicArn, criticalSubject(message), JSON.stringify(message, null, 2))
        }
        yield* queue.send({
          queueUrl: deliveryQueueUrl,
          groupId: message.fingerprint,
          deduplicationId: message.transitionId,
          body: record.body,
        })
        yield* journal.advance(message.transitionId, "ROUTED")
      }),
    )
  })

export const layer = Layer.mergeAll(JournalLive, QueueLive, NotifierLive).pipe(
  Layer.provide(Layer.mergeAll(Dynamo.Live, Sqs.Live, Sns.Live)),
)
