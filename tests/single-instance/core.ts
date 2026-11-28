import { Cmd } from "@native-sdk/core";

export interface Model { readonly log: Uint8Array; }
export type ChannelState = "data" | "closed" | "rejected";
export type SourceState = "started" | "skipped" | "failed";
export type Msg =
  | { readonly kind: "log_path"; readonly value: Uint8Array }
  | { readonly kind: "launch"; readonly key: number; readonly state: ChannelState; readonly bytes: Uint8Array; readonly droppedPending: number; readonly droppedTotal: number }
  | { readonly kind: "source_started"; readonly key: number; readonly state: SourceState; readonly bytes: Uint8Array }
  | { readonly kind: "saved" }
  | { readonly kind: "failed"; readonly why: Uint8Array };

export const envMsgs = [{ env: "LAUNCH_PROBE_LOG", msg: "log_path" }] as const;
export const viewUnbound = ["log", "launch", "source_started", "saved", "failed", "log_path"] as const;

export function initialModel(): Model { return { log: new Uint8Array(0) }; }

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "log_path":
      if (msg.value.length === 0) return model;
      return [{ log: msg.value }, Cmd.channelOpenSource(1, "native-sdk.app.launches", new Uint8Array(0), { event: "launch", started: "source_started" })];
    case "launch":
      if (msg.state !== "data") return model;
      return [model, Cmd.writeFile(model.log, msg.bytes, { key: "log", ok: "saved", err: "failed" })];
    case "source_started":
      if (msg.state !== "started") return model;
      return [model, Cmd.writeFile(model.log, new Uint8Array(0), { key: "ready", ok: "saved", err: "failed" })];
    case "saved":
    case "failed":
      return model;
  }
}
