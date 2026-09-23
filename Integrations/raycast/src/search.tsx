import {
  Action,
  ActionPanel,
  Icon,
  List,
  showToast,
  Toast,
} from "@raycast/api";
import { useEffect, useState } from "react";
import { hasIndex, Hit, openRunie, search, Source } from "./runie";

const sourceTitle: Record<Source, string> = {
  files: "Files",
  mail: "Mail",
  notes: "Notes",
  messages: "Messages",
  photos: "Photos",
  history: "Browsing History",
};

const sourceIcon: Record<Source, Icon> = {
  files: Icon.Document,
  mail: Icon.Envelope,
  notes: Icon.Paragraph,
  messages: Icon.Message,
  photos: Icon.Image,
  history: Icon.Globe,
};

export default function Command() {
  const [text, setText] = useState("");
  const [hits, setHits] = useState<Hit[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    search(text)
      .then((found) => {
        if (!cancelled) setHits(found);
      })
      .catch((error: Error) => {
        showToast({
          style: Toast.Style.Failure,
          title: "Could not open the index",
          message: error.message,
        });
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [text]);

  if (!hasIndex()) {
    return (
      <List>
        <List.EmptyView
          icon={Icon.MagnifyingGlass}
          title="The index is empty"
          description="Turn it on in Runie: Settings → General → Index."
          actions={
            <ActionPanel>
              <Action
                title="Open Runie"
                icon={Icon.Bubble}
                onAction={() => openRunie("open")}
              />
            </ActionPanel>
          }
        />
      </List>
    );
  }

  return (
    <List
      isLoading={loading}
      isShowingDetail={hits.length > 0}
      onSearchTextChange={setText}
      searchBarPlaceholder="Words from an email, a note, a page title…"
      throttle
    >
      <List.EmptyView
        icon={Icon.Bubble}
        title={text ? "No matching words" : "Start typing"}
        description={text ? "Runie can search by meaning — ask it." : undefined}
        actions={
          text ? (
            <ActionPanel>
              <Action
                title="Ask Runie"
                icon={Icon.Bubble}
                onAction={() => openRunie("ask", `Find in my stuff: ${text}`)}
              />
            </ActionPanel>
          ) : undefined
        }
      />
      {hits.map((hit) => (
        <List.Item
          key={`${hit.source}|${hit.externalID}`}
          icon={sourceIcon[hit.source] ?? Icon.Dot}
          title={hit.title}
          accessories={[{ date: new Date(hit.date * 1000) }]}
          detail={<Detail hit={hit} />}
          actions={<HitActions hit={hit} query={text} />}
        />
      ))}
    </List>
  );
}

function Detail({ hit }: { hit: Hit }) {
  const from = hit.details.from ?? hit.details.chat ?? hit.details.host;
  return (
    <List.Item.Detail
      markdown={`### ${escape(hit.title)}\n\n${escape(hit.body)}`}
      metadata={
        <List.Item.Detail.Metadata>
          <List.Item.Detail.Metadata.Label
            title="Source"
            text={sourceTitle[hit.source]}
          />
          <List.Item.Detail.Metadata.Label
            title="Date"
            text={new Date(hit.date * 1000).toLocaleString()}
          />
          {from ? (
            <List.Item.Detail.Metadata.Label title="From" text={from} />
          ) : null}
        </List.Item.Detail.Metadata>
      }
    />
  );
}

function HitActions({ hit, query }: { hit: Hit; query: string }) {
  const ask = (
    <Action
      title="Ask Runie About This"
      icon={Icon.Bubble}
      shortcut={{ modifiers: ["cmd", "shift"], key: "r" }}
      onAction={() =>
        openRunie(
          "ask",
          `Tell me more about “${hit.title}”${query ? ` (I searched for “${query}”)` : ""}`,
        )
      }
    />
  );
  return (
    <ActionPanel>
      {hit.source === "files" ? (
        <>
          <Action.Open title="Open" target={hit.externalID} />
          <Action.ShowInFinder path={hit.externalID} />
        </>
      ) : null}
      {hit.source === "history" ? (
        <Action.OpenInBrowser url={hit.externalID.replace(/^page:/, "")} />
      ) : null}
      {ask}
      <Action.CopyToClipboard title="Copy Title" content={hit.title} />
      {hit.source === "files" ? (
        <Action.CopyToClipboard title="Copy Path" content={hit.externalID} />
      ) : null}
    </ActionPanel>
  );
}

/** Text for the detail Markdown — without stray markup from the emails themselves. */
function escape(text: string): string {
  return text.replace(/([\\`*_{}[\]<>#|])/g, "\\$1");
}
