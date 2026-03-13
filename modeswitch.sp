// ============================================================================
// ospw CS:GO — Mode Switch Plugin (v3.0 — rotation + vote)
// ============================================================================
// Auto-rotates modes after a configurable number of maps per mode.
// When rotation triggers, all players vote on the next mode.
// Manual switch via !modes (triggers vote) or !modes <name> (admin direct).
//
// Commands:
//   !modes         - Opens mode vote for all players
//   !modes <name>  - Admin direct switch (no vote)
//   !map <name>    - Admin map change within current mode
//   !maps          - Admin map selection menu
//   !currentmode   - Shows current mode
//
// Deploy: addons/sourcemod/plugins/modeswitch.smx (always loaded)
// ============================================================================

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

// ── Mode definitions ────────────────────────────────────────────────────────
#define MODE_COUNT 6

#define MODE_COMPETITIVE 0
#define MODE_RETAKE      1
#define MODE_SURF        2
#define MODE_DM          3
#define MODE_ARENA       4
#define MODE_KZ          5

char g_sModeIDs[MODE_COUNT][] = {
    "competitive",
    "retake",
    "surf",
    "dm",
    "arena",
    "kz"
};

char g_sModeNames[MODE_COUNT][] = {
    "Competitive (5v5)",
    "Retake",
    "Surf",
    "FFA Deathmatch",
    "1v1 Arena",
    "KZ / Climb"
};

char g_sModeConfigs[MODE_COUNT][] = {
    "",
    "retake.cfg",
    "surf.cfg",
    "dm.cfg",
    "arena.cfg",
    "kz.cfg"
};

// Maps to play per mode before auto-rotation vote triggers
// comp=1 match, retake=1, surf=1, dm=2, arena=1 (30 rounds), kz=1
int g_iModeMapLimit[MODE_COUNT] = {
    1,  // competitive — 1 full match
    1,  // retake
    1,  // surf — 30 min
    2,  // dm — 2x 10 min
    1,  // arena — 30 rounds on 1 map
    1   // kz — 45 min
};

// ── State ───────────────────────────────────────────────────────────────────
int g_iCurrentMode = MODE_COMPETITIVE;
int g_iMapsPlayed = 0;
bool g_bRotationVoteActive = false;
Handle g_hTipTimer = INVALID_HANDLE;

// Vote tracking
int g_iVotes[MODE_COUNT];
bool g_bHasVoted[MAXPLAYERS + 1];
Handle g_hVoteTimer = INVALID_HANDLE;

// Manual switch
Handle g_hSwitchTimer = INVALID_HANDLE;
int g_iPendingMode = -1;
int g_iCountdown = 0;
char g_sPendingMap[PLATFORM_MAX_PATH];

// Map list from config
StringMap g_hMapNames[MODE_COUNT];
ArrayList g_hMapFiles[MODE_COUNT];

// ── Plugin info ─────────────────────────────────────────────────────────────
public Plugin myinfo = {
    name        = "ospw Mode Switch",
    author      = "ospw",
    description = "Mode rotation with voting for multi-mode CS:GO server",
    version     = "3.0.0",
    url         = "https://github.com/osk4r8088/csgo-server-ospw2026"
};

// ============================================================================
// Initialization
// ============================================================================

public void OnPluginStart()
{
    for (int i = 0; i < MODE_COUNT; i++)
    {
        g_hMapNames[i] = new StringMap();
        g_hMapFiles[i] = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    }

    LoadMapConfig();

    // !modes — admin only (auto-rotation vote is the democratic part)
    RegAdminCmd("sm_modes", Cmd_Modes, ADMFLAG_CHANGEMAP, "Switch game mode (admin direct or vote)");
    // !map / !maps — admin only
    RegAdminCmd("sm_map", Cmd_Map, ADMFLAG_CHANGEMAP, "Change map within current mode");
    RegAdminCmd("sm_maps", Cmd_Map, ADMFLAG_CHANGEMAP, "Alias for sm_map");
    RegConsoleCmd("sm_currentmode", Cmd_CurrentMode, "Show current game mode");

    DetectCurrentMode();

    LogMessage("[ModeSwitch] v3.0 loaded. Mode: %s | Maps played: %d / %d",
        g_sModeIDs[g_iCurrentMode], g_iMapsPlayed, g_iModeMapLimit[g_iCurrentMode]);
}

public void OnMapStart()
{
    g_iMapsPlayed++;

    // Re-exec mode config to override Valve defaults
    if (g_iCurrentMode != MODE_COMPETITIVE)
    {
        CreateTimer(1.5, Timer_ReExecConfig, _, TIMER_FLAG_NO_MAPCHANGE);
    }

    // Start periodic tips
    if (g_hTipTimer != INVALID_HANDLE)
        KillTimer(g_hTipTimer);
    g_hTipTimer = CreateTimer(180.0, Timer_ShowTips, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    // Show tips on map start (delayed so players load in)
    CreateTimer(15.0, Timer_ShowTips, _, TIMER_FLAG_NO_MAPCHANGE);

    // Check if rotation should trigger
    if (g_iMapsPlayed > g_iModeMapLimit[g_iCurrentMode])
    {
        // Delay vote slightly so players load in
        CreateTimer(20.0, Timer_AutoRotationVote, _, TIMER_FLAG_NO_MAPCHANGE);
        PrintToChatAll(" \x04[ospw]\x01 Mode rotation in 20 seconds — get ready to vote!");
    }
    else
    {
        int remaining = g_iModeMapLimit[g_iCurrentMode] - g_iMapsPlayed + 1;
        if (remaining == 1)
        {
            PrintToChatAll(" \x04[ospw]\x01 Last map in \x03%s\x01 mode — mode vote after this!",
                g_sModeNames[g_iCurrentMode]);
        }
    }
}

public void OnClientDisconnect(int client)
{
    g_bHasVoted[client] = false;
}

// ============================================================================
// Config loading
// ============================================================================

void LoadMapConfig()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "configs/modeswitch_maps.cfg");

    KeyValues kv = new KeyValues("ModeSwitchMaps");
    if (!kv.ImportFromFile(path))
    {
        LogError("[ModeSwitch] Could not load config: %s", path);
        delete kv;
        return;
    }

    for (int i = 0; i < MODE_COUNT; i++)
    {
        g_hMapNames[i].Clear();
        g_hMapFiles[i].Clear();

        if (!kv.JumpToKey(g_sModeIDs[i]))
            continue;

        if (!kv.GotoFirstSubKey(false))
        {
            kv.GoBack();
            continue;
        }

        do
        {
            char mapFile[PLATFORM_MAX_PATH];
            char mapName[128];
            kv.GetSectionName(mapFile, sizeof(mapFile));
            kv.GetString(NULL_STRING, mapName, sizeof(mapName), mapFile);
            g_hMapFiles[i].PushString(mapFile);
            g_hMapNames[i].SetString(mapFile, mapName);
        }
        while (kv.GotoNextKey(false));

        kv.GoBack();
        kv.GoBack();
    }

    delete kv;
}

// ============================================================================
// Mode detection
// ============================================================================

void DetectCurrentMode()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "data/currentmode.txt");
    File f = OpenFile(path, "r");
    if (f != null)
    {
        char modeName[32];
        if (f.ReadLine(modeName, sizeof(modeName)))
        {
            TrimString(modeName);
            int mode = FindModeByID(modeName);
            if (mode != -1)
            {
                g_iCurrentMode = mode;
                delete f;
                return;
            }
        }
        delete f;
    }

    // Fallback: detect from loaded plugins
    char pluginName[64];
    Handle iter = GetPluginIterator();
    while (MorePlugins(iter))
    {
        Handle plugin = ReadPlugin(iter);
        if (plugin == INVALID_HANDLE) continue;
        GetPluginFilename(plugin, pluginName, sizeof(pluginName));

        if (StrContains(pluginName, "retakes") != -1 && StrContains(pluginName, "modeswitch") == -1)
        { g_iCurrentMode = MODE_RETAKE; break; }
        else if (StrContains(pluginName, "SurfTimer") != -1)
        { g_iCurrentMode = MODE_SURF; break; }
        else if (StrContains(pluginName, "multi1v1") != -1)
        { g_iCurrentMode = MODE_ARENA; break; }
        else if (StrContains(pluginName, "gokz") != -1)
        { g_iCurrentMode = MODE_KZ; break; }
    }
    delete iter;
}

// ============================================================================
// !modes command
// ============================================================================

public Action Cmd_Modes(int client, int args)
{
    if (args > 0)
    {
        // Direct switch — admin only
        if (!CheckCommandAccess(client, "sm_map", ADMFLAG_CHANGEMAP, false))
        {
            ReplyToCommand(client, "[SM] You don't have access to direct mode switch. Use !modes to vote.");
            return Plugin_Handled;
        }

        char modeName[32];
        GetCmdArg(1, modeName, sizeof(modeName));

        int mode = FindModeByID(modeName);
        if (mode == -1)
        {
            ReplyToCommand(client, "[SM] Unknown mode: %s", modeName);
            return Plugin_Handled;
        }

        if (mode == g_iCurrentMode)
        {
            ReplyToCommand(client, "[SM] Already in %s mode.", g_sModeNames[mode]);
            return Plugin_Handled;
        }

        // Admin direct switch — no vote, immediate countdown
        StartDirectSwitch(mode);
        return Plugin_Handled;
    }

    // No args — start a mode vote
    if (g_bRotationVoteActive)
    {
        ReplyToCommand(client, "[SM] A mode vote is already active!");
        return Plugin_Handled;
    }

    StartModeVote();
    return Plugin_Handled;
}

// ============================================================================
// !map command (admin only)
// ============================================================================

public Action Cmd_Map(int client, int args)
{
    if (args == 0)
    {
        ShowMapMenu(client);
        return Plugin_Handled;
    }

    char mapName[PLATFORM_MAX_PATH];
    GetCmdArg(1, mapName, sizeof(mapName));

    if (!IsMapValid(mapName))
    {
        ReplyToCommand(client, "[SM] Map not found: %s", mapName);
        return Plugin_Handled;
    }

    char currentMap[PLATFORM_MAX_PATH];
    GetCurrentMap(currentMap, sizeof(currentMap));
    if (StrEqual(mapName, currentMap, false))
    {
        ReplyToCommand(client, "[SM] Already on %s.", mapName);
        return Plugin_Handled;
    }

    PrintToChatAll(" \x04[SM]\x01 Changing map to \x03%s\x01...", mapName);
    strcopy(g_sPendingMap, sizeof(g_sPendingMap), mapName);
    CreateTimer(1.0, Timer_JustChangeMap, _, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Handled;
}

public Action Timer_JustChangeMap(Handle timer)
{
    if (IsMapValid(g_sPendingMap))
        ForceChangeLevel(g_sPendingMap, "Admin map change");
    return Plugin_Stop;
}

void ShowMapMenu(int client)
{
    Menu menu = new Menu(MapMenuHandler);
    menu.SetTitle("Maps (%s)", g_sModeNames[g_iCurrentMode]);

    int count = g_hMapFiles[g_iCurrentMode].Length;
    if (count == 0)
    {
        menu.AddItem("", "No maps configured", ITEMDRAW_DISABLED);
    }
    else
    {
        char currentMap[PLATFORM_MAX_PATH];
        GetCurrentMap(currentMap, sizeof(currentMap));

        for (int i = 0; i < count; i++)
        {
            char mapFile[PLATFORM_MAX_PATH];
            char mapDisplayName[128];
            char display[160];

            g_hMapFiles[g_iCurrentMode].GetString(i, mapFile, sizeof(mapFile));
            g_hMapNames[g_iCurrentMode].GetString(mapFile, mapDisplayName, sizeof(mapDisplayName));

            bool isCurrent = StrEqual(mapFile, currentMap, false);
            bool isValid = IsMapValid(mapFile);

            if (isCurrent)
                Format(display, sizeof(display), "%s [CURRENT]", mapDisplayName);
            else if (!isValid)
                Format(display, sizeof(display), "%s [NOT INSTALLED]", mapDisplayName);
            else
                Format(display, sizeof(display), "%s", mapDisplayName);

            menu.AddItem(mapFile, display, (isCurrent || !isValid) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
        }
    }
    menu.Display(client, 30);
}

public int MapMenuHandler(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        char mapFile[PLATFORM_MAX_PATH];
        menu.GetItem(item, mapFile, sizeof(mapFile));
        if (IsMapValid(mapFile))
        {
            PrintToChatAll(" \x04[SM]\x01 Changing map to \x03%s\x01...", mapFile);
            strcopy(g_sPendingMap, sizeof(g_sPendingMap), mapFile);
            CreateTimer(1.0, Timer_JustChangeMap, _, TIMER_FLAG_NO_MAPCHANGE);
        }
    }
    else if (action == MenuAction_End)
        delete menu;
    return 0;
}

// ============================================================================
// !currentmode
// ============================================================================

public Action Cmd_CurrentMode(int client, int args)
{
    char currentMap[PLATFORM_MAX_PATH];
    GetCurrentMap(currentMap, sizeof(currentMap));
    int remaining = g_iModeMapLimit[g_iCurrentMode] - g_iMapsPlayed + 1;
    if (remaining < 0) remaining = 0;
    ReplyToCommand(client, "[SM] Mode: %s | Map: %s | Maps left: %d",
        g_sModeNames[g_iCurrentMode], currentMap, remaining);
    return Plugin_Handled;
}

// ============================================================================
// Mode Vote System
// ============================================================================

public Action Timer_AutoRotationVote(Handle timer)
{
    StartModeVote();
    return Plugin_Stop;
}

void StartModeVote()
{
    if (g_bRotationVoteActive)
        return;

    g_bRotationVoteActive = true;

    // Reset votes
    for (int i = 0; i < MODE_COUNT; i++)
        g_iVotes[i] = 0;
    for (int i = 0; i <= MAXPLAYERS; i++)
        g_bHasVoted[i] = false;

    // Show vote menu to all real players
    int playerCount = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            ShowVoteMenu(i);
            playerCount++;
        }
    }

    if (playerCount == 0)
    {
        // No players — pick random mode
        g_bRotationVoteActive = false;
        int nextMode = GetRandomModeExcept(g_iCurrentMode);
        DoModeSwitch(nextMode);
        return;
    }

    PrintToChatAll(" \x04=============================================");
    PrintToChatAll(" \x04[ospw]\x01 VOTE: Choose the next game mode!");
    PrintToChatAll(" \x04[ospw]\x01 You have 20 seconds to vote.");
    PrintToChatAll(" \x04=============================================");

    g_hVoteTimer = CreateTimer(20.0, Timer_TallyVotes, _, TIMER_FLAG_NO_MAPCHANGE);
}

void ShowVoteMenu(int client)
{
    Menu menu = new Menu(VoteMenuHandler);
    menu.SetTitle("Vote: Next Game Mode");
    menu.ExitButton = false;

    for (int i = 0; i < MODE_COUNT; i++)
    {
        char info[8];
        IntToString(i, info, sizeof(info));

        char display[64];
        if (i == g_iCurrentMode)
            Format(display, sizeof(display), "%s [CURRENT]", g_sModeNames[i]);
        else
            Format(display, sizeof(display), "%s", g_sModeNames[i]);

        menu.AddItem(info, display);
    }

    menu.Display(client, 20);
}

public int VoteMenuHandler(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        if (!g_bHasVoted[client])
        {
            char info[8];
            menu.GetItem(item, info, sizeof(info));
            int mode = StringToInt(info);

            if (mode >= 0 && mode < MODE_COUNT)
            {
                g_iVotes[mode]++;
                g_bHasVoted[client] = true;

                char name[64];
                GetClientName(client, name, sizeof(name));
                PrintToChatAll(" \x04[Vote]\x01 %s voted for \x03%s", name, g_sModeNames[mode]);
            }
        }
    }
    else if (action == MenuAction_End)
        delete menu;
    return 0;
}

public Action Timer_TallyVotes(Handle timer)
{
    g_hVoteTimer = INVALID_HANDLE;
    g_bRotationVoteActive = false;

    // Find winner
    int winnerMode = -1;
    int maxVotes = 0;
    int totalVotes = 0;

    for (int i = 0; i < MODE_COUNT; i++)
    {
        totalVotes += g_iVotes[i];
        if (g_iVotes[i] > maxVotes)
        {
            maxVotes = g_iVotes[i];
            winnerMode = i;
        }
    }

    // No votes — pick random different mode
    if (totalVotes == 0 || winnerMode == -1)
    {
        winnerMode = GetRandomModeExcept(g_iCurrentMode);
        PrintToChatAll(" \x04[ospw]\x01 No votes — randomly selected \x03%s\x01!", g_sModeNames[winnerMode]);
    }
    else
    {
        PrintToChatAll(" \x04[ospw]\x01 \x03%s\x01 wins with %d vote%s!",
            g_sModeNames[winnerMode], maxVotes, maxVotes == 1 ? "" : "s");
    }

    // Switch to winner
    PrintToChatAll(" ");
    PrintToChatAll(" \x04[ospw]\x01 Server restarting in 5 seconds...");
    PrintToChatAll(" \x04[ospw]\x01 Type \x03retry\x01 in your console to reconnect!");
    PrintToChatAll(" ");
    g_iPendingMode = winnerMode;
    g_iCountdown = 5;
    g_hSwitchTimer = CreateTimer(1.0, Timer_SwitchCountdown, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    return Plugin_Stop;
}

// ============================================================================
// Admin direct switch (no vote)
// ============================================================================

void StartDirectSwitch(int mode)
{
    PrintToChatAll(" ");
    PrintToChatAll(" \x04[SM]\x01 Admin switching to \x03%s\x01 in 5 seconds...", g_sModeNames[mode]);
    PrintToChatAll(" \x04[ospw]\x01 Type \x03retry\x01 in your console to reconnect!");
    PrintToChatAll(" ");
    g_iPendingMode = mode;
    g_iCountdown = 5;
    g_hSwitchTimer = CreateTimer(1.0, Timer_SwitchCountdown, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_SwitchCountdown(Handle timer)
{
    g_iCountdown--;

    if (g_iCountdown > 0)
    {
        PrintCenterTextAll("Restarting in %d...", g_iCountdown);
        return Plugin_Continue;
    }

    g_hSwitchTimer = INVALID_HANDLE;
    DoModeSwitch(g_iPendingMode);
    return Plugin_Stop;
}

// ============================================================================
// Execute mode switch — write file and quit
// ============================================================================

void DoModeSwitch(int mode)
{
    if (mode < 0 || mode >= MODE_COUNT)
        return;

    // Write pending mode
    char modePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, modePath, sizeof(modePath), "data/pendingmode.txt");
    File f = OpenFile(modePath, "w");
    if (f != null)
    {
        f.WriteLine("%s", g_sModeIDs[mode]);
        delete f;
        LogMessage("[ModeSwitch] Wrote mode '%s' to %s", g_sModeIDs[mode], modePath);
    }
    else
    {
        LogError("[ModeSwitch] Could not write %s", modePath);
    }

    ServerCommand("quit");
}

// ============================================================================
// Re-exec config on map start
// ============================================================================

public Action Timer_ReExecConfig(Handle timer)
{
    if (g_iCurrentMode >= 0 && g_iCurrentMode < MODE_COUNT)
    {
        if (g_sModeConfigs[g_iCurrentMode][0] != '\0')
        {
            ServerCommand("exec %s", g_sModeConfigs[g_iCurrentMode]);
            LogMessage("[ModeSwitch] Re-executed %s on map start.", g_sModeConfigs[g_iCurrentMode]);
        }
    }
    return Plugin_Stop;
}

// ============================================================================
// Periodic tips
// ============================================================================

public Action Timer_ShowTips(Handle timer)
{
    // General tips (all modes)
    PrintToChatAll(" \x04[ospw]\x01 Type \x03!ws !knife !gloves\x01 to set your skins!");
    PrintToChatAll(" \x04[ospw]\x01 Type \x03!rtv\x01 to start a map vote | \x03!modes\x01 to switch game mode");

    // Mode-specific tips
    switch (g_iCurrentMode)
    {
        case MODE_KZ:
        {
            PrintToChatAll(" \x04[ospw]\x01 Type \x03!menu\x01 to set & load checkpoints!");
            PrintToChatAll(" \x04[ospw]\x01 Type \x03!options\x01 to configure your KZ settings");
        }
        case MODE_SURF:
        {
            PrintToChatAll(" \x04[ospw]\x01 Type \x03!r\x01 to restart | \x03!s\x01 to go back to start");
        }
    }

    return Plugin_Continue;
}

// ============================================================================
// Helpers
// ============================================================================

int FindModeByID(const char[] id)
{
    for (int i = 0; i < MODE_COUNT; i++)
    {
        if (StrEqual(g_sModeIDs[i], id, false))
            return i;
    }
    return -1;
}

int GetRandomModeExcept(int excludeMode)
{
    int mode;
    do {
        mode = GetRandomInt(0, MODE_COUNT - 1);
    } while (mode == excludeMode);
    return mode;
}
