// Vite's `?raw` import: the file's text. Used to compare wrangler.toml with the code.
declare module "*?raw" {
  const text: string;
  export default text;
}
