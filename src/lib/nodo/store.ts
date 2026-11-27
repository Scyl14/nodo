import { create } from "zustand";
import { persist } from "zustand/middleware";

export type View = "console" | "neighbor";
export type Access = "pending" | "approved" | "rejected";

export type Person = {
  id: string;
  name: string;
  status: Access;
  requestedAt: number;
};

export type Post = {
  id: string;
  author: string;
  body: string;
  at: number;
};

export type Preset = {
  id: string;
  name: string;
  mhz: string;
};

type NodoState = {
  passwordHash: string | null;
  recoveryCode: string | null;
  recoveryAcknowledged: boolean;
  unlocked: boolean;
  view: View;
  neighborId: string;
  people: Person[];
  posts: Post[];
  presets: Preset[];
  clockOffsetMs: number;
  clockSetByHand: boolean;
  ramGb: number;
  setup: (password: string) => void;
  acknowledgeRecovery: () => void;
  unlock: (password: string) => boolean;
  unlockWithRecovery: (code: string) => boolean;
  lock: () => void;
  setView: (view: View) => void;
  requestAccess: (name: string) => void;
  decide: (id: string, status: Access) => void;
  addPost: (body: string) => void;
  addPreset: (name: string, mhz: string) => string | null;
  removePreset: (id: string) => void;
  setClock: (epochMs: number) => void;
  setRam: (ramGb: number) => void;
};

function hashSecret(value: string): string {
  let hash = 2166136261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0).toString(16);
}

function codeChunk() {
  const alphabet = "abcdefghjkmnpqrstuvwxyz23456789";
  return Array.from({ length: 4 }, () => alphabet[Math.floor(Math.random() * alphabet.length)]).join("");
}

function newRecoveryCode() {
  return `${codeChunk()}-${codeChunk()}-${codeChunk()}`;
}

export function modelTier(ramGb: number) {
  if (ramGb < 8) {
    return {
      name: "Small, 1–3B",
      detail: "Ships with the node. It runs with the internet unplugged.",
    };
  }
  if (ramGb < 16) {
    return {
      name: "Medium, 7–8B Q4",
      detail: "Offered when a network is up. The small model stays installed.",
    };
  }
  return {
    name: "Large, 14B class",
    detail: "Only if memory and disk allow. The small model stays installed.",
  };
}

export const useNodo = create<NodoState>()(
  persist(
    (set, get) => ({
      passwordHash: null,
      recoveryCode: null,
      recoveryAcknowledged: false,
      unlocked: false,
      view: "console",
      neighborId: "",
      people: [],
      posts: [],
      presets: [],
      clockOffsetMs: 0,
      clockSetByHand: false,
      ramGb: 8,
      setup: (password) => {
        set({
          passwordHash: hashSecret(password),
          recoveryCode: newRecoveryCode(),
          recoveryAcknowledged: false,
          unlocked: true,
          view: "console",
        });
      },
      acknowledgeRecovery: () => set({ recoveryAcknowledged: true }),
      unlock: (password) => {
        const ok = get().passwordHash === hashSecret(password);
        if (ok) set({ unlocked: true, view: "console" });
        return ok;
      },
      unlockWithRecovery: (code) => {
        const expected = get().recoveryCode?.trim().toLowerCase();
        const ok = Boolean(expected) && expected === code.trim().toLowerCase();
        if (ok) set({ unlocked: true, view: "console" });
        return ok;
      },
      lock: () => set({ unlocked: false, view: "console" }),
      setView: (view) => set({ view }),
      requestAccess: (name) => {
        const trimmed = name.trim().slice(0, 40);
        if (!trimmed) return;
        const id = get().neighborId;
        const existing = get().people.find((person) => person.id === id);
        if (existing?.status === "approved") return;
        const next: Person = {
          id,
          name: trimmed,
          status: "pending",
          requestedAt: Date.now() + get().clockOffsetMs,
        };
        set({
          people: existing
            ? get().people.map((person) => (person.id === id ? next : person))
            : [next, ...get().people],
        });
      },
      decide: (id, status) => {
        set({
          people: get().people.map((person) => (person.id === id ? { ...person, status } : person)),
        });
      },
      addPost: (body) => {
        const text = body.trim().slice(0, 240);
        if (!text) return;
        const { view, neighborId, people, clockOffsetMs } = get();
        const person = people.find((entry) => entry.id === neighborId);
        if (view === "neighbor" && person?.status !== "approved") return;
        if (view === "console" && !get().unlocked) return;
        const author = view === "console" ? "Owner" : person?.name ?? "Neighbor";
        const post: Post = {
          id: crypto.randomUUID(),
          author,
          body: text,
          at: Date.now() + clockOffsetMs,
        };
        set({ posts: [post, ...get().posts].slice(0, 40) });
      },
      addPreset: (name, mhz) => {
        const label = name.trim().slice(0, 32);
        const value = Number(mhz);
        if (!label) return "Name the station.";
        if (!Number.isFinite(value) || value < 87.5 || value > 108) {
          return "FM broadcast only, from 87.5 to 108 MHz.";
        }
        const preset: Preset = {
          id: crypto.randomUUID(),
          name: label,
          mhz: value.toFixed(1),
        };
        set({ presets: [...get().presets, preset] });
        return null;
      },
      removePreset: (id) => set({ presets: get().presets.filter((preset) => preset.id !== id) }),
      setClock: (epochMs) => set({ clockOffsetMs: epochMs - Date.now(), clockSetByHand: true }),
      setRam: (ramGb) => set({ ramGb }),
    }),
    {
      name: "nodo-console",
      partialize: (state) => ({
        passwordHash: state.passwordHash,
        recoveryCode: state.recoveryCode,
        recoveryAcknowledged: state.recoveryAcknowledged,
        unlocked: state.unlocked,
        neighborId: state.neighborId,
        people: state.people,
        posts: state.posts,
        presets: state.presets,
        clockOffsetMs: state.clockOffsetMs,
        clockSetByHand: state.clockSetByHand,
        ramGb: state.ramGb,
      }),
      onRehydrateStorage: () => (state) => {
        if (state && !state.neighborId) {
          state.neighborId = crypto.randomUUID();
        }
      },
    },
  ),
);

export function nowMs(offset: number) {
  return Date.now() + offset;
}

export function formatWhen(epochMs: number) {
  return new Intl.DateTimeFormat("en-GB", {
    hour: "2-digit",
    minute: "2-digit",
    day: "2-digit",
    month: "short",
  }).format(epochMs);
}
