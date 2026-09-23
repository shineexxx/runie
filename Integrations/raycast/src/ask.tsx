import { LaunchProps } from "@raycast/api";
import { openRunie } from "./runie";

export default async function Command(
  props: LaunchProps<{ arguments: { question: string } }>,
) {
  await openRunie("ask", props.arguments.question);
}
