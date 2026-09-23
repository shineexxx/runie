import { Action, ActionPanel, Icon, List, showToast, Toast } from "@raycast/api";
import { useEffect, useState } from "react";
import { hasIndex, Hit, openRunie, search, Source } from "./runie";

const sourceTitle: Record<Source, string> = {
  files: "Файлы",
  mail: "Почта",
  notes: "Заметки",
  messages: "Сообщения",
  photos: "Фото",
  history: "История браузера",
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
        showToast({ style: Toast.Style.Failure, title: "Указатель не открылся", message: error.message });
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
          title="Указатель ещё не собран"
          description="Включите его в Руни: Настройки → Общие → Индекс."
          actions={
            <ActionPanel>
              <Action title="Открыть Руни" icon={Icon.Bubble} onAction={() => openRunie("open")} />
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
      searchBarPlaceholder="Что ищем: слова из письма, заметки, названия страницы…"
      throttle
    >
      <List.EmptyView
        icon={Icon.Bubble}
        title={text ? "По словам ничего нет" : "Начните печатать"}
        description={text ? "Руни ищет и по смыслу — спросите его." : undefined}
        actions={
          text ? (
            <ActionPanel>
              <Action
                title="Спросить Руни"
                icon={Icon.Bubble}
                onAction={() => openRunie("ask", `Найди у меня: ${text}`)}
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
          <List.Item.Detail.Metadata.Label title="Откуда" text={sourceTitle[hit.source]} />
          <List.Item.Detail.Metadata.Label title="Когда" text={new Date(hit.date * 1000).toLocaleString("ru-RU")} />
          {from ? <List.Item.Detail.Metadata.Label title="Кто или где" text={from} /> : null}
        </List.Item.Detail.Metadata>
      }
    />
  );
}

function HitActions({ hit, query }: { hit: Hit; query: string }) {
  const ask = (
    <Action
      title="Спросить Руни об этом"
      icon={Icon.Bubble}
      shortcut={{ modifiers: ["cmd"], key: "r" }}
      onAction={() => openRunie("ask", `Расскажи подробнее: «${hit.title}»${query ? ` (искал «${query}»)` : ""}`)}
    />
  );
  return (
    <ActionPanel>
      {hit.source === "files" ? (
        <>
          <Action.Open title="Открыть" target={hit.externalID} />
          <Action.ShowInFinder path={hit.externalID} />
        </>
      ) : null}
      {hit.source === "history" ? <Action.OpenInBrowser url={hit.externalID.replace(/^page:/, "")} /> : null}
      {ask}
      <Action.CopyToClipboard title="Скопировать название" content={hit.title} />
      {hit.source === "files" ? <Action.CopyToClipboard title="Скопировать путь" content={hit.externalID} /> : null}
    </ActionPanel>
  );
}

/** Текст в Markdown подробностей — без случайной разметки из самих писем. */
function escape(text: string): string {
  return text.replace(/([\\`*_{}[\]<>#|])/g, "\\$1");
}
