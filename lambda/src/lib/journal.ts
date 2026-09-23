/**
 * AlertEventJournal: durable record of every alert transition received. The Journal (not Keep and
 * not the SQS dedup window) is the source of truth for idempotency and for replay.
 */
import {
  ConditionalCheckFailedException,
  GetItemCommand,
  PutItemCommand,
  UpdateItemCommand,
} from "@aws-sdk/client-dynamodb"
import { Config, Context, Effect, Layer } from "effect"
import { AwsError, Dynamo } from "./aws.ts"

/** Delivery states in pipeline order. A state is only ever moved forward. */
export const JournalStates = ["RECEIVED", "QUEUED", "ROUTED", "KEEP_ACCEPTED"] as const
export type JournalState = (typeof JournalStates)[number]
const rank = (state: JournalState) => JournalStates.indexOf(state)

export interface JournalEntry {
  readonly transitionId: string
  readonly source: string
  readonly fingerprint: string
  readonly status: string
  readonly severity: string
  readonly receivedAt: string
  readonly payload: string
}

export type PutResult = { readonly _tag: "Created" } | { readonly _tag: "Exists"; readonly state: JournalState }

export interface JournalShape {
  /** Conditional put. Returns the existing state when the transition was already recorded. */
  readonly putReceived: (entry: JournalEntry) => Effect.Effect<PutResult, AwsError>
  /** Moves the entry forward to `state`. A no-op when it is already at or past `state`. */
  readonly advance: (
    transitionId: string,
    state: JournalState,
    attributes?: Readonly<Record<string, string>>,
  ) => Effect.Effect<void, AwsError>
}

export class Journal extends Context.Tag("Journal")<Journal, JournalShape>() {}

export const JournalLive = Layer.effect(
  Journal,
  Effect.gen(function* () {
    const tableName = yield* Config.string("JOURNAL_TABLE_NAME")
    const ttlDays = yield* Config.integer("JOURNAL_TTL_DAYS").pipe(Config.withDefault(30))
    const client = yield* Dynamo

    const readState = (transitionId: string) =>
      Effect.tryPromise({
        try: () =>
          client.send(
            new GetItemCommand({
              TableName: tableName,
              Key: { transition_id: { S: transitionId } },
              ConsistentRead: true,
              ProjectionExpression: "#state",
              ExpressionAttributeNames: { "#state": "state" },
            }),
          ),
        catch: (cause) => new AwsError({ operation: "dynamodb:GetItem", cause }),
      }).pipe(Effect.map((out) => (out.Item?.state?.S ?? "RECEIVED") as JournalState))

    const putReceived: JournalShape["putReceived"] = (entry) => {
      const now = new Date()
      const expiresAt = Math.floor(now.getTime() / 1000) + ttlDays * 86_400
      return Effect.tryPromise({
        try: () =>
          client.send(
            new PutItemCommand({
              TableName: tableName,
              Item: {
                transition_id: { S: entry.transitionId },
                source: { S: entry.source },
                fingerprint: { S: entry.fingerprint },
                alert_status: { S: entry.status },
                severity: { S: entry.severity },
                received_at: { S: entry.receivedAt },
                payload: { S: entry.payload },
                state: { S: "RECEIVED" },
                state_rank: { N: String(rank("RECEIVED")) },
                updated_at: { S: now.toISOString() },
                expires_at: { N: String(expiresAt) },
              },
              ConditionExpression: "attribute_not_exists(transition_id)",
            }),
          ),
        catch: (cause) => cause,
      }).pipe(
        Effect.as<PutResult>({ _tag: "Created" }),
        Effect.catchAll((cause) =>
          cause instanceof ConditionalCheckFailedException
            ? readState(entry.transitionId).pipe(Effect.map((state): PutResult => ({ _tag: "Exists", state })))
            : Effect.fail(new AwsError({ operation: "dynamodb:PutItem", cause })),
        ),
      )
    }

    const advance: JournalShape["advance"] = (transitionId, state, attributes = {}) => {
      const extra = Object.entries(attributes)
      const setExtra = extra.map((_, i) => `, #a${i} = :a${i}`).join("")
      return Effect.tryPromise({
        try: () =>
          client.send(
            new UpdateItemCommand({
              TableName: tableName,
              Key: { transition_id: { S: transitionId } },
              UpdateExpression: `SET #state = :state, state_rank = :rank, updated_at = :now${setExtra}`,
              ConditionExpression: "attribute_exists(transition_id) AND state_rank < :rank",
              ExpressionAttributeNames: {
                "#state": "state",
                ...Object.fromEntries(extra.map(([name], i) => [`#a${i}`, name])),
              },
              ExpressionAttributeValues: {
                ":state": { S: state },
                ":rank": { N: String(rank(state)) },
                ":now": { S: new Date().toISOString() },
                ...Object.fromEntries(extra.map(([, value], i) => [`:a${i}`, { S: value }])),
              },
            }),
          ),
        catch: (cause) => cause,
      }).pipe(
        Effect.asVoid,
        Effect.catchAll((cause) =>
          // Already at or beyond `state` (or unknown id): moving backwards is never wanted.
          cause instanceof ConditionalCheckFailedException
            ? Effect.logDebug("journal state not advanced", { transitionId, state })
            : Effect.fail(new AwsError({ operation: "dynamodb:UpdateItem", cause })),
        ),
      )
    }

    return { putReceived, advance }
  }),
)
