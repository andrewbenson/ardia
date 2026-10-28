export type Script = { name: string; devices: Record<string, object>; steps: object[]; scope?: string };
export function runScenario(script: Script, options?: { swift?: string | null }): Promise<object[]>;
export function randomScript(seed: number, steps: number): Script;
export function randomRedesignScript(seed: number, steps: number): Script;
export function namedScripts(): Script[];
export function namedRedesignScripts(): Script[];
