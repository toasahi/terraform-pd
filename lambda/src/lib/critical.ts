/**
 * Critical alert notification: the message delivered to every Keep-independent channel
 * (the in-house notifier's SQS queue and the critical-direct SNS topic).
 *
 * Contract (docs/critical-notification-contract.md): JSON, schemaVersion 1. Delivery is
 * at-least-once on every channel; consumers must deduplicate on `transitionId`.
 */
import { Schema } from "effect"
import type { PipelineMessage } from "./schema.ts"

/** Keep-independent delivery channels, recorded per transition in the Journal. */
export const CriticalChannels = ["inhouse", "sns"] as const
export type CriticalChannel = (typeof CriticalChannels)[number]

const StringMap = Schema.Record({ key: Schema.String, value: Schema.String })

export const CriticalNotification = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  transitionId: Schema.String,
  source: Schema.String,
  fingerprint: Schema.String,
  status: Schema.Literal("firing", "resolved"),
  severity: Schema.String,
  alertname: Schema.String,
  summary: Schema.optional(Schema.String),
  description: Schema.optional(Schema.String),
  startsAt: Schema.String,
  endsAt: Schema.optional(Schema.String),
  generatorURL: Schema.optional(Schema.String),
  receivedAt: Schema.String,
  labels: StringMap,
  annotations: StringMap,
})
export type CriticalNotification = typeof CriticalNotification.Type

const optional = <K extends string>(key: K, value: string | undefined) =>
  (value === undefined || value === "" ? {} : { [key]: value }) as { [P in K]?: string }

export const criticalNotification = (message: PipelineMessage): CriticalNotification => {
  const { alert } = message
  const annotations = alert.annotations ?? {}
  return {
    schemaVersion: 1,
    transitionId: message.transitionId,
    source: message.source,
    fingerprint: message.fingerprint,
    status: message.status,
    severity: message.severity,
    alertname: alert.labels.alertname ?? "unknown",
    ...optional("summary", annotations.summary),
    ...optional("description", annotations.description),
    startsAt: alert.startsAt,
    // Alertmanager sends the zero time for alerts that are still firing.
    ...optional("endsAt", alert.endsAt?.startsWith("0001-01-01") ? undefined : alert.endsAt),
    ...optional("generatorURL", alert.generatorURL),
    receivedAt: message.receivedAt,
    labels: alert.labels,
    annotations,
  }
}

export const criticalSubject = (notification: CriticalNotification) =>
  `[${notification.status.toUpperCase()}] ${notification.alertname} (${notification.source})`

export const encodeCriticalNotification = Schema.encodeSync(Schema.parseJson(CriticalNotification))
