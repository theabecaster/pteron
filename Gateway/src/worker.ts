/**
 * The Worker's entry: the handlers and the Durable Object class, and nothing else. The
 * runtime takes every export of the entry module as an entrypoint and refuses one that is
 * not a function, a handler or a class (a constant such as VERSION), so the constants and
 * helpers stay in src/index.ts, where the tests import them.
 */
export { default } from "./index";
export { Presence } from "./presence";
