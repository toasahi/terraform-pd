import { SendMessageCommand } from "@aws-sdk/client-sqs"
import { Context, Effect, Layer } from "effect"
import { AwsError, Sqs } from "./aws.ts"

export interface QueueMessage {
  readonly queueUrl: string
  /** MessageGroupId / MessageDeduplicationId: used for FIFO queues (URL ending in .fifo), ignored otherwise. */
  readonly groupId: string
  readonly deduplicationId: string
  readonly body: string
}

export interface QueueShape {
  readonly send: (message: QueueMessage) => Effect.Effect<void, AwsError>
}

export class Queue extends Context.Tag("Queue")<Queue, QueueShape>() {}

export const isFifoQueue = (queueUrl: string) => queueUrl.endsWith(".fifo")

export const QueueLive = Layer.effect(
  Queue,
  Effect.map(Sqs, (client) => ({
    send: (message) =>
      Effect.tryPromise({
        try: () =>
          client.send(
            new SendMessageCommand({
              QueueUrl: message.queueUrl,
              MessageBody: message.body,
              ...(isFifoQueue(message.queueUrl)
                ? { MessageGroupId: message.groupId, MessageDeduplicationId: message.deduplicationId }
                : {}),
            }),
          ),
        catch: (cause) => new AwsError({ operation: "sqs:SendMessage", cause }),
      }).pipe(Effect.asVoid),
  })),
)
