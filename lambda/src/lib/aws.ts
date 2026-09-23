import { DynamoDBClient } from "@aws-sdk/client-dynamodb"
import { SecretsManagerClient } from "@aws-sdk/client-secrets-manager"
import { SNSClient } from "@aws-sdk/client-sns"
import { SQSClient } from "@aws-sdk/client-sqs"
import { Context, Data, Layer } from "effect"

/** Raw AWS SDK clients. Region and credentials come from the Lambda environment. */
export class Dynamo extends Context.Tag("Dynamo")<Dynamo, DynamoDBClient>() {
  static readonly Live = Layer.sync(Dynamo, () => new DynamoDBClient({}))
}
export class Sqs extends Context.Tag("Sqs")<Sqs, SQSClient>() {
  static readonly Live = Layer.sync(Sqs, () => new SQSClient({}))
}
export class Sns extends Context.Tag("Sns")<Sns, SNSClient>() {
  static readonly Live = Layer.sync(Sns, () => new SNSClient({}))
}
export class SecretsManager extends Context.Tag("SecretsManager")<SecretsManager, SecretsManagerClient>() {
  static readonly Live = Layer.sync(SecretsManager, () => new SecretsManagerClient({}))
}

export class AwsError extends Data.TaggedError("AwsError")<{
  readonly operation: string
  readonly cause: unknown
}> {}
