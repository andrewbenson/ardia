import { cancelShortcutRecording, recordShortcut, Symbol, type MenuShortcut } from "@ardia/shell";
import { useEffect, useMemo, useState } from "react";
import { Pressable, Text, View } from "react-native";
import { useTheme } from "../../../lib/theme";
import { useBrowser } from "../../../store/browser";
import { openUrls } from "../../../lib/actions";
import { IconButton, useHover } from "../../primitives";
import { matchesQuery } from "../../pages/PageLayout";
import { Anchor, Button, Group, PopUp, Row, SearchField, SectionHeader, Toggle, useFormColors } from "../controls";
import { shortcutItems } from "../paneData";
import { useResource } from "../native/resources";
import { PRODUCT } from "../../../lib/productName";
import { resolvedShortcuts, useMenuBarRevision } from "../../../lib/commandShortcuts";
import { formatShortcut, sameShortcut, type Shortcut } from "../../../lib/shortcuts";

type Filter = "all" | "customized" | "conflicts";

const NO_SHORTCUT: Shortcut = { key: "", modifiers: [] };

export function ShortcutsPane() {
  const theme = useTheme();
  const overrides = useBrowser((s) => s.settings.shortcuts);
  const profileOrder = useBrowser((s) => s.profileOrder);
  const menuBar = useMenuBarRevision();
  const undoReopensClosedTab = useBrowser((s) => s.settings.undoReopensClosedTab);
  const [loaded] = useResource(shortcutItems);
  const items = loaded ?? null;
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState<Filter>("all");
  const [recording, setRecording] = useState<string | null>(null);

  useEffect(() => () => void cancelShortcutRecording(), []);

  const resolved = useMemo(() => resolvedShortcuts({ settings: { shortcuts: overrides }, profileOrder }), [items, overrides, profileOrder, menuBar]);
  const byId = useMemo(() => new Map((items ?? []).map((item) => [item.id, item])), [items]);
  const effective = (item: MenuShortcut): Shortcut => resolved.bindings.get(item.id)?.[0] ?? NO_SHORTCUT;
  const conflictsOf = (item: MenuShortcut) => resolved.conflictsOf(item.id).flatMap((id) => byId.get(id) ?? []);

  const setShortcut = (id: string, combo: Shortcut | null) => {
    const next = { ...useBrowser.getState().settings.shortcuts };
    if (combo) next[id] = [combo.key, ...combo.modifiers];
    else delete next[id];
    useBrowser.getState().updateSettings({ shortcuts: next });
  };

  const record = async (item: MenuShortcut) => {
    setRecording(item.id);
    const combo = await recordShortcut();
    setRecording(null);
    if (!combo) return;
    const isDefault = sameShortcut(combo, { key: item.defaultKey, modifiers: item.defaultModifiers });
    setShortcut(item.id, isDefault ? null : combo);
  };

  const shown = (items ?? []).filter((item) => {
    if (!matchesQuery(query, item.title, item.path.join(" "), formatShortcut(effective(item)))) return false;
    if (filter === "customized") return !!overrides[item.id];
    if (filter === "conflicts") return conflictsOf(item).length > 0;
    return true;
  });
  const menus = [...new Set(shown.map((i) => i.path[0] ?? ""))];
  const customizedCount = Object.keys(overrides).length;

  return (
    <View>
      <Text style={{ marginTop: 20, fontSize: 12.5, lineHeight: 17, color: theme.textSecondary }}>
        Perform common actions in {PRODUCT} faster and from anywhere. Select an action to customize its keyboard shortcut.
      </Text>
      <Group style={{ marginTop: 14 }}>
        <Row anchor="shortcuts.undoReopensClosedTab">
          <Toggle value={undoReopensClosedTab} onChange={(v) => useBrowser.getState().updateSettings({ undoReopensClosedTab: v })} />
        </Row>
      </Group>
      <Anchor id="shortcuts.actions" radius={8} style={{ flexDirection: "row", alignItems: "center", gap: 8, marginTop: 14 }}>
        <SearchField value={query} onChangeText={setQuery} placeholder="Search actions" style={{ flex: 1 }} />
        <PopUp
          value={filter}
          options={[
            { value: "all", title: "All Shortcuts" },
            { value: "customized", title: "Customized Shortcuts" },
            { value: "conflicts", title: "Conflicting Shortcuts" },
          ]}
          onChange={setFilter}
          minWidth={170}
        />
        <Button title="Reset All Shortcuts" disabled={!customizedCount} onPress={() => useBrowser.getState().updateSettings({ shortcuts: {} })} />
      </Anchor>
      {items !== null && shown.length === 0 && (
        <Text style={{ marginTop: 30, textAlign: "center", fontSize: 13, color: theme.textTertiary }}>No matching actions</Text>
      )}
      {menus.map((menu) => (
        <View key={menu}>
          <SectionHeader title={menu} />
          <Group>
            {shown
              .filter((i) => (i.path[0] ?? "") === menu)
              .map((item) => {
                const others = conflictsOf(item);
                return (
                  <Row
                    key={item.id}
                    title={item.title}
                    description={
                      others.length ? (
                        <Text style={{ fontSize: 11.5, marginTop: 2, color: "#FF9F0A" }}>
                          {`${others.length === 1 ? "This shortcut conflicts with another shortcut:" : "This shortcut conflicts with other shortcuts:"} ${others.map((o) => o.title).join(", ")}`}
                        </Text>
                      ) : item.path.length > 1 ? (
                        item.path.slice(1).join(" › ")
                      ) : undefined
                    }
                  >
                    {overrides[item.id] && (
                      <IconButton icon="arrow.uturn.backward" size={11} box={24} radius={6} onPress={() => setShortcut(item.id, null)} tooltip="Reset to Default" />
                    )}
                    <ShortcutField
                      combo={effective(item)}
                      remappable={item.remappable}
                      recording={recording === item.id}
                      onRecord={() => void record(item)}
                      onClear={() => setShortcut(item.id, item.defaultKey ? { key: "", modifiers: [] } : null)}
                    />
                  </Row>
                );
              })}
          </Group>
        </View>
      ))}
      {filter === "all" && !query && (
        <>
          <SectionHeader title="Extensions" />
          <Group>
            <Row anchor="shortcuts.extensionShortcuts">
              <Button title="Edit…" onPress={() => openUrls(["chrome://extensions/shortcuts"])} />
            </Row>
          </Group>
        </>
      )}
    </View>
  );
}

function ShortcutField({
  combo,
  remappable,
  recording,
  onRecord,
  onClear,
}: {
  combo: Shortcut;
  remappable: boolean;
  recording: boolean;
  onRecord: () => void;
  onClear: () => void;
}) {
  const theme = useTheme();
  const colors = useFormColors();
  const { hovered, hoverProps } = useHover();
  const text = recording ? "Type Shortcut" : formatShortcut(combo);
  if (!remappable) {
    return (
      <View style={{ minWidth: 110, alignItems: "flex-end" }} tooltip="(not remappable)">
        <Text style={{ fontSize: 13, color: theme.textTertiary }}>{text || "—"}</Text>
      </View>
    );
  }
  return (
    <View {...hoverProps}>
      <Pressable onPress={onRecord}>
        <View
          style={{
            minWidth: 110,
            height: 24,
            paddingHorizontal: 8,
            borderRadius: 6,
            flexDirection: "row",
            alignItems: "center",
            justifyContent: "center",
            gap: 4,
            backgroundColor: recording ? `${colors.accent}33` : hovered ? colors.controlHover : colors.control,
            borderWidth: recording ? 1.5 : 1,
            borderColor: recording ? colors.accent : colors.controlBorder,
          }}
        >
          <Text style={{ flex: 1, textAlign: "center", fontSize: 13, color: recording ? colors.accent : text ? theme.textPrimary : theme.textTertiary }}>
            {text || "None"}
          </Text>
          {hovered && !recording && combo.key ? (
            <Pressable onPress={onClear} tooltip="Remove Shortcut">
              <Symbol name="xmark.circle.fill" size={11} color={theme.textTertiary} style={{ width: 14, height: 14 }} />
            </Pressable>
          ) : null}
        </View>
      </Pressable>
    </View>
  );
}
