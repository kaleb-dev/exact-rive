import type { Answer, Sources } from './app.contract.d.ts';

export const grants = '';

// The example asks for no data: everything it shows comes from the Rive file.
const sources: Sources = {};
export const answer: Answer = (source, args, store, storage, native) => sources[source](args, store, storage, native);
