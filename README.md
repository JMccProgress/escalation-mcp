# escalation-mcp

An MCP server that enforces a consistent, high-quality Engineering escalation standard across the support team. Every engineer escalates the same way, to the same bar — every time.

## Why an MCP?

A document describing the escalation checklist is easy to ignore, skip, or interpret differently. An MCP is an **implementable piece of code**: it runs against the actual case, checks the evidence, and won't generate the escalation form until every item genuinely passes. The standard is in the tool, not in someone's memory.

Because it's built on the [Model Context Protocol](https://modelcontextprotocol.io), it works with GitHub Copilot CLI, Claude Desktop, Cursor, or any AI assistant that supports MCP servers — no vendor lock-in, and any team member can use it with whatever AI tooling they already have.

**What it does:**
1. Receives the Salesforce case and comments (fetched by the AI agent via SF MCP tools and passed in)
2. Runs the 6-item escalation checklist heuristically against the evidence
3. Searches Jira for duplicate tickets
4. Flags any attached support bundle for log analysis
5. Interviews the engineer for every amber/red item — and pushes back on weak answers
6. Generates a complete, copy-paste-ready SF escalation form package only when all items pass

## Quick Start

```
escalation check 01234567
```

The agent fetches the case and comments via your connected SF MCP tools, passes them to the escalation-mcp server, and runs the full checklist. See [Setup](#setup) to get connected.

## Prerequisites

- Ruby >= 3.0
- Salesforce credentials via one of:
  - `SALESFORCE_ACCESS_TOKEN` + `SALESFORCE_INSTANCE_URL` env vars
  - `SF_MCP_TOKEN_FILE` pointing at an mcp-remote OAuth token JSON + `SALESFORCE_INSTANCE_URL`
  - [Salesforce CLI (`sf`)](https://developer.salesforce.com/tools/salesforcecli) installed and authenticated (legacy)

## Setup

1. Add to `~/.copilot/mcp-config.json`:

```json
"escalation-mcp": {
  "command": "/path/to/escalation-mcp/bin/escalation-mcp"
}
```

2. Wire up the agent workflow instructions from `copilot-instructions.md` so the agent knows the full escalation workflow:

   - **GitHub Copilot CLI:** append the contents to `~/.copilot/copilot-instructions.md`
   - **Claude Desktop:** add as a system prompt in your Claude Desktop config
   - **Cursor:** add to your `.cursorrules` file or Cursor system prompt settings
   - **Other MCP-compatible agents:** add the contents wherever your agent accepts custom system/workflow instructions

## Usage

In Copilot CLI: `escalation check XXXXXXX` (where XXXXXXX is the SF case number)

The agent will:
1. Fetch the full case + all comments from Salesforce via your connected SF MCP tools and pass them to the server
2. Run the 6-item checklist heuristically and search Jira for duplicates
3. Flag any attached support bundle for log analysis if tooling is available
4. Interview you for any amber/red items — pushing back on weak or vague answers
5. Generate a complete, copy-paste-ready SF escalation form package once all items pass

## Configuration

| Env var | Default | Purpose |
|---------|---------|---------|
| `SALESFORCE_ACCESS_TOKEN` | — | SF access token (takes priority over all other methods) |
| `SF_MCP_TOKEN_FILE` | — | Path to an mcp-remote OAuth token JSON file (fallback if no access token) |
| `SALESFORCE_INSTANCE_URL` | — | SF instance URL (required alongside either token method above) |
| `SF_ORG_ALIAS` | auto-detect | SF CLI org alias (legacy fallback, requires `sf` installed) |
| `SF_RENEWAL_DATE_FIELD` | `Contract_Expiration_Date__c` | Account renewal date field name |
| `JIRA_URL` | — | Jira instance URL (e.g. `https://yourorg.atlassian.net`) |
| `JIRA_EMAIL` | — | Jira credentials for duplicate search |
| `JIRA_API_TOKEN` | — | Jira credentials for duplicate search |
| `RED_ACCOUNTS` | — | Comma-separated list of at-risk account names to flag as red |
| `YELLOW_ACCOUNTS` | — | Comma-separated list of at-risk account names to flag as amber |

## Checklist Items

1. Customer environment & product version (OS, hardware, exact versions)
2. Full logs across all nodes (not partial or single-node)
3. Initial RCA or hypothesis with supporting log evidence
4. Workarounds attempted, including CA/DD guidance sought
5. Steps to reproduce (or formal note if not feasible)
6. AI-assisted analysis used (checkit, Copilot, RAG KB)
