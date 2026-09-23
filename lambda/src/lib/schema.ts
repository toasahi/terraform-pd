import { Schema } from "effect"

/** One alert in an Alertmanager webhook (payload version 4). */
export const AlertmanagerAlert = Schema.Struct({
  status: Schema.Literal("firing", "resolved"),
  labels: Schema.Record({ key: Schema.String, value: Schema.String }),
  annotations: Schema.optional(Schema.Record({ key: Schema.String, value: Schema.String })),
  startsAt: Schema.String,
  endsAt: Schema.optional(Schema.String),
  generatorURL: Schema.optional(Schema.String),
  fingerprint: Schema.String.pipe(Schema.minLength(1)),
})
export type AlertmanagerAlert = typeof AlertmanagerAlert.Type

/** Alertmanager webhook_config payload. Unknown fields are ignored. */
export const AlertmanagerWebhook = Schema.Struct({
  version: Schema.String,
  groupKey: Schema.String,
  status: Schema.Literal("firing", "resolved"),
  receiver: Schema.String,
  externalURL: Schema.optional(Schema.String),
  alerts: Schema.Array(AlertmanagerAlert),
})
export type AlertmanagerWebhook = typeof AlertmanagerWebhook.Type

/** Message carried on alerts.fifo and keep-delivery.fifo. */
export const PipelineMessage = Schema.Struct({
  transitionId: Schema.String,
  source: Schema.String,
  fingerprint: Schema.String,
  status: Schema.Literal("firing", "resolved"),
  severity: Schema.String,
  receivedAt: Schema.String,
  receiver: Schema.String,
  externalURL: Schema.optional(Schema.String),
  alert: AlertmanagerAlert,
})
export type PipelineMessage = typeof PipelineMessage.Type

export const decodePipelineMessage = Schema.decodeUnknown(Schema.parseJson(PipelineMessage))
export const encodePipelineMessage = Schema.encode(Schema.parseJson(PipelineMessage))

/** Secret format for the per-source ingest tokens: source -> sha256 hex digest(s) of the token. */
export const SourceTokenDigests = Schema.Record({
  key: Schema.String,
  value: Schema.Union(Schema.String, Schema.Array(Schema.String)),
})
export type SourceTokenDigests = typeof SourceTokenDigests.Type

/** API Gateway REST proxy event (only the fields the ingest handler reads). */
export const RestProxyEvent = Schema.Struct({
  body: Schema.NullOr(Schema.String),
  isBase64Encoded: Schema.optional(Schema.Boolean),
  pathParameters: Schema.NullOr(Schema.Record({ key: Schema.String, value: Schema.String })),
  requestContext: Schema.Struct({
    requestId: Schema.String,
    authorizer: Schema.optional(Schema.NullOr(Schema.Record({ key: Schema.String, value: Schema.Unknown }))),
  }),
})

/** API Gateway REST REQUEST authorizer event (only the fields the authorizer reads). */
export const RequestAuthorizerEvent = Schema.Struct({
  methodArn: Schema.String,
  headers: Schema.optional(Schema.NullOr(Schema.Record({ key: Schema.String, value: Schema.String }))),
  pathParameters: Schema.optional(Schema.NullOr(Schema.Record({ key: Schema.String, value: Schema.String }))),
})

/** SQS event delivered by an event source mapping. */
export const SqsEvent = Schema.Struct({
  Records: Schema.Array(
    Schema.Struct({
      messageId: Schema.String,
      body: Schema.String,
    }),
  ),
})
export type SqsRecord = (typeof SqsEvent.Type)["Records"][number]
