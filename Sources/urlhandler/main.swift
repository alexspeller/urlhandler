import URLHandlerKit

// No arguments -> run as the resident default-browser agent (used when macOS launches us).
// Otherwise -> run the CLI (route/open/resolve/list-profiles/set-default).
runMain(CommandLine.arguments)
