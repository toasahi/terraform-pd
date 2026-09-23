import { ConfigProvider, Effect, Layer } from "effect"
import { Journal, type JournalEntry, type JournalShape, type JournalState, JournalStates } from "../src/lib/journal.ts"
import type { QueueMessage, QueueShape } from "../src/lib/queue.ts"
import { Queue } from "../src/lib/queue.ts"
import { Notifier } from "../src/lib/notifier.ts"
import type { AlertmanagerAlert } from "../src/lib/schema.ts"

export const alert = (overrides: Partial<AlertmanagerAlert> = {}): AlertmanagerAlert => ({
  status: "firing",
  labels: { alertname: "KubePodCrashLooping", severity: "critical", namespace: "default" },
  annotations: { summary: "pod is crash looping" },
  startsAt: "2026-09-23T00:00:00Z",
  endsAt: "0001-01-01T00:00:00Z",
  generatorURL: "http://prometheus/graph",
  fingerprint: "a1b2c3d4e5f60708",
  ...overrides,
})

export const webhook = (alerts: ReadonlyArray<AlertmanagerAlert>) => ({
  version: "4",
  groupKey: '{}:{alertname="KubePodCrashLooping"}',
  truncatedAlerts: 0,
  status: "firing",
  receiver: "keep",
  groupLabels: {},
  commonLabels: {},
  commonAnnotations: {},
  externalURL: "http://alertmanager",
  alerts,
})

/** In-memory Journal with the same forward-only semantics as the DynamoDB implementation. */
export const makeMemoryJournal = () => {
  const items = new Map<
    string,
    JournalEntry & { state: JournalState; attributes: Record<string, string>; channels: Set<string> }
  >()
  const service: JournalShape = {
    putReceived: (entry) =>
      Effect.sync(() => {
        const existing = items.get(entry.transitionId)
        if (existing) return { _tag: "Exists", state: existing.state } as const
        items.set(entry.transitionId, { ...entry, state: "RECEIVED", attributes: {}, channels: new Set() })
        return { _tag: "Created" } as const
      }),
    advance: (id, state, attributes = {}) =>
      Effect.sync(() => {
        const item = items.get(id)
        if (item && JournalStates.indexOf(item.state) < JournalStates.indexOf(state)) {
          item.state = state
          Object.assign(item.attributes, attributes)
        }
      }),
    deliveredChannels: (id) => Effect.sync(() => new Set(items.get(id)?.channels ?? [])),
    markChannelDelivered: (id, channel) => Effect.sync(() => void items.get(id)?.channels.add(channel)),
  }
  return { items, layer: Layer.succeed(Journal, service) }
}

export const makeMemoryQueue = (failOn?: (message: QueueMessage) => boolean) => {
  const sent: QueueMessage[] = []
  const service: QueueShape = {
    send: (message) =>
      failOn?.(message)
        ? Effect.fail({ _tag: "AwsError", operation: "sqs:SendMessage", cause: "boom" } as never)
        : Effect.sync(() => void sent.push(message)),
  }
  return { sent, layer: Layer.succeed(Queue, service) }
}

export const makeMemoryNotifier = (fail: () => boolean = () => false) => {
  const published: Array<{ topicArn: string; subject: string; message: string }> = []
  return {
    published,
    layer: Layer.succeed(Notifier, {
      publish: (topicArn, subject, message) =>
        fail()
          ? Effect.fail({ _tag: "AwsError", operation: "sns:Publish", cause: "boom" } as never)
          : Effect.sync(() => void published.push({ topicArn, subject, message })),
    }),
  }
}

export const withEnv = (env: Record<string, string>) =>
  Layer.setConfigProvider(ConfigProvider.fromMap(new Map(Object.entries(env))))
