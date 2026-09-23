/**
 * Receives Alertmanager webhooks from API Gateway, records every alert transition in the Journal
 * (conditional put) and enqueues it on alerts.fifo.
 *
 * Alertmanager retries 5xx only (4xx including 429 are dropped), so any internal failure MUST be
 * answered with 5xx. A transition that was journaled but never queued (state RECEIVED) is queued
 * again when Alertmanager retries; the FIFO dedup id absorbs double sends within five minutes.
 */
import { Config, Effect, Either, Layer, Schema } from "effect"
import { Dynamo, Sqs } from "../lib/aws.ts"
import { Journal, JournalLive } from "../lib/journal.ts"
import { Queue, QueueLive } from "../lib/queue.ts"
import { AlertmanagerWebhook, encodePipelineMessage, RestProxyEvent } from "../lib/schema.ts"
import { scopedFingerprint, transitionId } from "../lib/transition-id.ts"

const response = (statusCode: number, body: unknown) => ({
  statusCode,
  headers: { "content-type": "application/json" },
  body: JSON.stringify(body),
})

export const handle = (event: unknown) =>
  Effect.gen(function* () {
    const queueUrl = yield* Config.string("ALERTS_QUEUE_URL")
    const journal = yield* Journal
    const queue = yield* Queue

    const request = yield* Schema.decodeUnknown(RestProxyEvent)(event)
    const source = request.pathParameters?.source
    const authorizedSource = request.requestContext.authorizer?.source
    if (source === undefined || source !== authorizedSource) {
      return response(403, { message: "source mismatch" })
    }

    const rawBody = request.isBase64Encoded === true ? Buffer.from(request.body ?? "", "base64").toString("utf8") : request.body ?? ""
    const decoded = yield* Schema.decodeUnknown(Schema.parseJson(AlertmanagerWebhook))(rawBody).pipe(Effect.either)
    if (Either.isLeft(decoded)) {
      yield* Effect.logWarning("ingest: payload rejected", { source, error: String(decoded.left) })
      return response(400, { message: "invalid Alertmanager webhook payload" })
    }
    const webhook = decoded.right
    const receivedAt = new Date().toISOString()

    const results = yield* Effect.forEach(
      webhook.alerts,
      (alert) =>
        Effect.gen(function* () {
          const id = transitionId(source, alert)
          const fingerprint = scopedFingerprint(source, alert.fingerprint)
          const severity = alert.labels.severity ?? "unknown"
          const body = yield* encodePipelineMessage({
            transitionId: id,
            source,
            fingerprint,
            status: alert.status,
            severity,
            receivedAt,
            receiver: webhook.receiver,
            ...(webhook.externalURL === undefined ? {} : { externalURL: webhook.externalURL }),
            alert,
          })
          const put = yield* journal.putReceived({
            transitionId: id,
            source,
            fingerprint,
            status: alert.status,
            severity,
            receivedAt,
            payload: body,
          })
          if (put._tag === "Exists" && put.state !== "RECEIVED") return "duplicate" as const
          yield* queue.send({ queueUrl, groupId: fingerprint, deduplicationId: id, body })
          yield* journal.advance(id, "QUEUED")
          return put._tag === "Created" ? ("accepted" as const) : ("requeued" as const)
        }),
      { concurrency: 10 },
    )

    const count = (kind: (typeof results)[number]) => results.filter((r) => r === kind).length
    const summary = { source, accepted: count("accepted"), requeued: count("requeued"), duplicates: count("duplicate") }
    yield* Effect.logInfo("ingest: webhook processed", summary)
    return response(200, summary)
  }).pipe(
    Effect.catchTags({
      ParseError: (error) => Effect.logError("ingest: malformed event", String(error)).pipe(Effect.as(response(400, { message: "bad request" }))),
      AwsError: (error) => Effect.logError("ingest: AWS failure", error).pipe(Effect.as(response(500, { message: "temporary failure" }))),
    }),
  )

export const layer = Layer.mergeAll(JournalLive, QueueLive).pipe(Layer.provide(Layer.mergeAll(Dynamo.Live, Sqs.Live)))
