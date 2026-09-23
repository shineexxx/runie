# Runie

[Runie](https://github.com/shineexxx/runie) is a native Mac assistant built on Claude Code: an orb at the edge of the screen and a glass chat above your desktop. This extension lets you ask Runie and search everything it has indexed without opening its chat.

| Command | What it does |
| --- | --- |
| **Ask Runie** | Opens the chat next to the orb and asks your question right away. |
| **Search Index** | Searches Runie's index: files, mail, notes, messages and browsing history. Files open in their app, pages in the browser, and you can ask Runie about anything else. |
| **Open Chat** | Opens the chat. |
| **Start New Conversation** | Starts a fresh conversation. |

## Setup

1. Install Runie from the [releases page](https://github.com/shineexxx/runie/releases) and sign in to Claude Code when it asks.
2. To search, turn the index on in Runie: **Settings → General → Index**. Runie builds it on your Mac; nothing leaves your computer until you ask a question.

## How it works

Search in Raycast goes straight to Runie's index database, by words and read-only. Searching by meaning needs Runie's own model, so when words find nothing the list offers **Ask Runie**.

Commands reach Runie through its `runie://` link. Runie sends a question from Raycast immediately; a link opened by any other app only fills in the input field, so a web page can't speak on your behalf.
