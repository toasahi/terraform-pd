import { SendMessageCommand } from "@aws-sdk/client-sqs"
import { Context, Effect, Layer } from "effect"
import { AwsError, Sqs } from "./aws.ts"

export interface FifoMessage {
  readonly queueUrl: string
  readonly groupId: string
  readonly deduplicationId: string
  readonly body: string
}

export interface QueueShape {
  readonly send: (message: FifoMessage) => Effect.Effect<void, AwsError>
}

export class Queue extends Context.Tag("Queue")<Queue, QueueShape>() {}

export const QueueLive = Layer.effect(
  Queue,
  Effect.map(Sqs, (client) => ({
    send: (message) =>
      Effect.tryPromise({
        try: () =>
          client.send(
            new SendMessageCommand({
              QueueUrl: message.queueUrl,
              MessageGroupId: message.groupId,
              MessageDeduplicationId: message.deduplicationId,
              MessageBody: message.body,
            }),
          ),
        catch: (cause) => new AwsError({ operation: "sqs:SendMessage", cause }),
      }).pipe(Effect.asVoid),
  })),
)
