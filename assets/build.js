const esbuild = require("esbuild")
const sveltePlugin = require("esbuild-svelte")
const importGlobPlugin = require("esbuild-plugin-import-glob").default
const sveltePreprocess = require("svelte-preprocess")

const args = process.argv.slice(2)
const watch = args.includes("--watch")
const deploy = args.includes("--deploy")

let clientConditions = ["svelte", "browser"]
let serverConditions = ["svelte"]

if (!deploy) {
    clientConditions.push("development")
    serverConditions.push("development")
}

let optsClient = {
    entryPoints: ["js/app.js"],
    bundle: true,
    minify: deploy,
    conditions: clientConditions,
    alias: {svelte: "svelte"},
    // Output to priv/static/assets/js so the served path matches the
    // <script src="/assets/js/app.js"> in root.html.heex (CSS lives in
    // priv/static/assets/css/app.css, written by tailwind).
    outdir: "../priv/static/assets/js",
    logLevel: "info",
    sourcemap: watch ? "inline" : false,
    tsconfig: "./tsconfig.json",
    // app.js branches on process.env.NODE_ENV for live_reload dev tooling.
    // The browser has no `process`, so esbuild must inline this value.
    define: {
        "process.env.NODE_ENV": deploy ? '"production"' : '"development"',
    },
    plugins: [
        importGlobPlugin(),
        sveltePlugin({
            preprocess: sveltePreprocess(),
            compilerOptions: {dev: !deploy, css: "injected", generate: "client"},
        }),
    ],
}

let optsServer = {
    entryPoints: ["js/server.js"],
    platform: "node",
    bundle: true,
    minify: false,
    target: "node19.6.1",
    conditions: serverConditions,
    alias: {svelte: "svelte"},
    outdir: "../priv/svelte",
    logLevel: "info",
    sourcemap: watch ? "inline" : false,
    tsconfig: "./tsconfig.json",
    plugins: [
        importGlobPlugin(),
        sveltePlugin({
            preprocess: sveltePreprocess(),
            compilerOptions: {dev: !deploy, css: "injected", generate: "server"},
        }),
    ],
}

if (watch) {
    esbuild
        .context(optsClient)
        .then(ctx => ctx.watch())
        .catch(_error => process.exit(1))

    esbuild
        .context(optsServer)
        .then(ctx => ctx.watch())
        .catch(_error => process.exit(1))
} else {
    esbuild.build(optsClient)
    esbuild.build(optsServer)
}
