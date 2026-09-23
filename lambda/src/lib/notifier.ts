import { PublishCommand } from "@aws-sdk/client-sns"
import { Context, Effect, Layer } from "effect"
import { AwsError, Sns } from "./aws.ts"

export interface NotifierShape {
  readonly publish: (topicArn: string, subject: string, message: string) => Effect.Effect<void, AwsError>
}

/** Direct (Keep-independent) notification channel for critical alerts. */
export class Notifier extends Context.Tag("Notifier")<Notifier, NotifierShape>() {}

export const NotifierLive = Layer.effect(
  Notifier,
  Effect.map(Sns, (client) => ({
    publish: (topicArn, subject, message) =>
      Effect.tryPromise({
        try: () =>
          client.send(
            // SNS subjects are limited to 100 characters.
            new PublishCommand({ TopicArn: topicArn, Subject: subject.slice(0, 100), Message: message }),
          ),
        catch: (cause) => new AwsError({ operation: "sns:Publish", cause }),
      }).pipe(Effect.asVoid),
  })),
)
