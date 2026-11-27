import { createServerFn } from "@tanstack/react-start";

export type ChatDisk = {
  free: number;
  total: number;
  chats: number;
  dir: string;
};

export const getChatDisk = createServerFn({ method: "POST" }).handler(async (): Promise<ChatDisk> => {
  const { mkdir, readdir, stat, statfs } = await import("node:fs/promises");
  const path = await import("node:path");
  const dir = process.env.NODO_CHAT_DIR || path.join(process.cwd(), "data", "nodo-chats");
  await mkdir(dir, { recursive: true });
  const disk = await statfs(dir);
  const names = await readdir(dir);
  let chats = 0;
  for (const name of names) {
    const file = await stat(path.join(dir, name));
    if (file.isFile()) chats += file.size;
  }
  return {
    free: disk.bavail * disk.bsize,
    total: disk.blocks * disk.bsize,
    chats,
    dir,
  };
});
