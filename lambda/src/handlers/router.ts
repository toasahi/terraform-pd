/**
 * Consumes alerts.fifo. Critical alerts are delivered to every Keep-independent channel — the
 * in-house notifier (its Lambda is triggered by the SQS queue we send to) and the critical-direct
 * SNS topic — so that critical delivery never depends on Keep. Every alert is then forwarded to
 * keep-delivery.fifo.
 *
 * Each channel is recorded in the Journal after a successful delivery; when a record is retried
 * (e.g. SNS failed after the in-house queue succeeded) only the missing channels are sent again.
 */
import { Config, Effect, Layer, Schema } from "effect"
import { Dynamo, Sns, Sqs } from "../lib/aws.ts"
import { type CriticalChannel, criticalNotification, criticalSubject, encodeCriticalNotification } from "../lib/critical.ts"
import { processFifoBatch } from "../lib/fifo-batch.ts"
import { Journal, JournalLive } from "../lib/journal.ts"
import { Notifier, NotifierLive } from "../lib/notifier.ts"
import { Queue, QueueLive } from "../lib/queue.ts"
import { decodePipelineMessage, type PipelineMessage, SqsEvent } from "../lib/schema.ts"

export const handle = (event: unknown) =>
  Effect.gen(function* () {
    const topicArn = yield* Config.string("CRITICAL_TOPIC_ARN")
    const inhouseQueueUrl = yield* Config.string("INHOUSE_NOTIFIER_QUEUE_URL")
    const deliveryQueueUrl = yield* Config.string("KEEP_DELIVERY_QUEUE_URL")
    const criticalSeverities = yield* Config.array(Config.string(), "CRITICAL_SEVERITIES").pipe(
      Config.withDefault<ReadonlyArray<string>>(["critical"]),
    )
    const journal = yield* Journal
    const queue = yield* Queue
    const notifier = yield* Notifier

    const deliverCritical = (message: PipelineMessage) =>
      Effect.gen(function* () {
        const notification = criticalNotification(message)
        const body = encodeCriticalNotification(notification)
        const channels: ReadonlyArray<readonly [CriticalChannel, Effect.Effect<void, unknown>]> = [
          // Primary: the in-house notifier.
          ["inhouse", queue.send({ queueUrl: inhouseQueueUrl, groupId: message.fingerprint, deduplicationId: message.transitionId, body })],
          ["sns", notifier.publish(topicArn, criticalSubject(notification), body)],
        ]
        const delivered = yield* journal.deliveredChannels(message.transitionId)
        for (const [channel, send] of channels) {
          if (delivered.has(channel)) continue
          yield* send
          yield* journal.markChannelDelivered(message.transitionId, channel)
        }
      })

    const { Records } = yield* Schema.decodeUnknown(SqsEvent)(event)
    return yield* processFifoBatch(Records, (record) =>
      Effect.gen(function* () {
        const message = yield* decodePipelineMessage(record.body)
        if (criticalSeverities.includes(message.severity)) yield* deliverCritical(message)
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
