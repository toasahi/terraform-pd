import { describe, expect, test } from "vitest"
import { scopedFingerprint, transitionId } from "../src/lib/transition-id.ts"
import { alert } from "./helpers.ts"

describe("transitionId", () => {
  test("is stable for re-notifications of the same firing alert", () => {
    expect(transitionId("prod", alert())).toBe(transitionId("prod", alert({ annotations: { summary: "changed" } })))
  })

  test("differs between firing and resolved", () => {
    expect(transitionId("prod", alert())).not.toBe(transitionId("prod", alert({ status: "resolved" })))
  })

  test("differs between sources with the same fingerprint", () => {
    expect(transitionId("prod", alert())).not.toBe(transitionId("management", alert()))
  })

  test("differs when the alert fires again later", () => {
    expect(transitionId("prod", alert())).not.toBe(transitionId("prod", alert({ startsAt: "2026-09-23T01:00:00Z" })))
  })

  test("scopedFingerprint prefixes the source", () => {
    expect(scopedFingerprint("prod", "abc")).toBe("prod:abc")
  })
})
