let refusedSession: string | null = null;

export function refusePersistence(sessionPath: string) {
  refusedSession ??= sessionPath;
}

export const persistenceRefused = () => refusedSession !== null;
export const refusedSessionPath = () => refusedSession;
