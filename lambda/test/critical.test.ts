import { Schema } from "effect"
import { describe, expect, test } from "vitest"
import { CriticalNotification, criticalNotification, encodeCriticalNotification } from "../src/lib/critical.ts"
import { isFifoQueue } from "../src/lib/queue.ts"
import { alert } from "./helpers.ts"

const base = {
  transitionId: "t-1",
  source: "management",
  fingerprint: "management:ffff",
  severity: "critical",
  receivedAt: "2026-09-23T00:00:01Z",
  receiver: "keep",
} as const

describe("criticalNotification", () => {
  test("keeps endsAt for resolved alerts and round-trips through the contract schema", () => {
    const n = criticalNotification({
      ...base,
      status: "resolved",
      alert: alert({ status: "resolved", endsAt: "2026-09-23T00:10:00Z", annotations: { summary: "s", description: "d" } }),
    })
    expect(n).toMatchObject({ status: "resolved", endsAt: "2026-09-23T00:10:00Z", summary: "s", description: "d" })
    expect(Schema.decodeUnknownSync(Schema.parseJson(CriticalNotification))(encodeCriticalNotification(n))).toEqual(n)
  })

  test("falls back to alertname 'unknown' and omits missing annotations", () => {
    const n = criticalNotification({ ...base, status: "firing", alert: alert({ labels: {}, annotations: {} }) })
    expect(n.alertname).toBe("unknown")
    expect(n).not.toHaveProperty("summary")
  })
})

describe("isFifoQueue", () => {
  test("detects FIFO queues by URL suffix", () => {
    expect(isFifoQueue("https://sqs.ap-northeast-1.amazonaws.com/1/q.fifo")).toBe(true)
    expect(isFifoQueue("https://sqs.ap-northeast-1.amazonaws.com/1/q")).toBe(false)
  })
})
