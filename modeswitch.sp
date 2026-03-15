// ============================================================================
// ospw CS:GO — Mode Switch Plugin (v4.1 — chat-based voting)
// ============================================================================
// Players: !switchmode (RTV-style, 60% threshold → chat vote)
// Admins:  !modes     (direct menu-based switch)
//          !map/!maps (admin map change)
//
// Regular players vote entirely in CHAT — no menus pop up.
// When 60% of players type !switchmode, a mode poll starts in chat.
// Players vote by typing "1", "2", "3", etc. in chat.
// Auto-rotation also uses the same chat-based vote system.
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

// Fraction of players needed to trigger !switchmode vote
#define SWITCHMODE_FRACTION 0.60

// Vote duration in seconds
#define VOTE_DURATION 25

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
Handle g_hTipTimer = INVALID_HANDLE;

// RTV-style switchmode requests
bool g_bWantsModeSwitch[MAXPLAYERS + 1];
int g_iSwitchModeRequests = 0;

// Chat-based vote state
bool g_bChatVoteActive = false;
int g_iChatVotes[MODE_COUNT];
bool g_bHasChatVoted[MAXPLAYERS + 1];
Handle g_hChatVoteTimer = INVALID_HANDLE;
// Which modes are voteable (excludes current mode)
int g_iVoteOptions[MODE_COUNT];  // maps option number (1-based) → mode index
int g_iVoteOptionCount = 0;

// Switch countdown
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
    description = "Chat-based mode voting for multi-mode CS:GO server",
    version     = "4.1.0",
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

    // Player commands (no admin required)
    RegConsoleCmd("sm_switchmode", Cmd_SwitchMode, "Request a mode switch (60% threshold)");

    // Admin commands
    RegAdminCmd("sm_modes", Cmd_Modes, ADMFLAG_CHANGEMAP, "Admin mode switch menu or direct switch");
    RegAdminCmd("sm_map", Cmd_Map, ADMFLAG_CHANGEMAP, "Change map within current mode");
    RegAdminCmd("sm_maps", Cmd_Map, ADMFLAG_CHANGEMAP, "Alias for sm_map");

    // Listen for chat messages (for "1", "2", "3" voting)
    AddCommandListener(Cmd_Say, "say");
    AddCommandListener(Cmd_Say, "say_team");

    DetectCurrentMode();

    LogMessage("[ModeSwitch] v4.1 loaded. Mode: %s | Maps played: %d / %d",
        g_sModeIDs[g_iCurrentMode], g_iMapsPlayed, g_iModeMapLimit[g_iCurrentMode]);
}

public void OnMapStart()
{
    g_iMapsPlayed++;

    // Reset all vote/switch state
    CancelAllVoteState();

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
    if (g_bWantsModeSwitch[client])
    {
        g_bWantsModeSwitch[client] = false;
        g_iSwitchModeRequests--;
        if (g_iSwitchModeRequests < 0) g_iSwitchModeRequests = 0;
    }
    g_bHasChatVoted[client] = false;
}

// ============================================================================
// State management
// ============================================================================

void CancelAllVoteState()
{
    // Reset switchmode requests
    for (int i = 0; i <= MAXPLAYERS; i++)
    {
        g_bWantsModeSwitch[i] = false;
        g_bHasChatVoted[i] = false;
    }
    g_iSwitchModeRequests = 0;

    // Reset chat vote
    g_bChatVoteActive = false;
    g_iVoteOptionCount = 0;
    for (int i = 0; i < MODE_COUNT; i++)
        g_iChatVotes[i] = 0;

    if (g_hChatVoteTimer != INVALID_HANDLE)
    {
        KillTimer(g_hChatVoteTimer);
        g_hChatVoteTimer = INVALID_HANDLE;
    }

    if (g_hSwitchTimer != INVALID_HANDLE)
    {
        KillTimer(g_hSwitchTimer);
        g_hSwitchTimer = INVALID_HANDLE;
    }
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
// !switchmode — RTV-style, 60% threshold, then chat vote
// ============================================================================

public Action Cmd_SwitchMode(int client, int args)
{
    if (!IsValidClient(client))
        return Plugin_Handled;

    if (g_bChatVoteActive)
    {
        PrintToChat(client, " \x04[ospw]\x01 A mode vote is already in progress! Vote by typing a number in chat.");
        return Plugin_Handled;
    }

    if (g_bWantsModeSwitch[client])
    {
        PrintToChat(client, " \x04[ospw]\x01 You already requested a mode switch.");
        return Plugin_Handled;
    }

    g_bWantsModeSwitch[client] = true;
    g_iSwitchModeRequests++;

    int playerCount = GetRealPlayerCount();
    int needed = RoundToCeil(float(playerCount) * SWITCHMODE_FRACTION);
    if (needed < 1) needed = 1;

    char name[64];
    GetClientName(client, name, sizeof(name));
    PrintToChatAll(" \x04[ospw]\x01 %s wants to switch mode! (\x03%d\x01/\x03%d\x01 needed)",
        name, g_iSwitchModeRequests, needed);

    if (g_iSwitchModeRequests >= needed)
    {
        PrintToChatAll(" \x04[ospw]\x01 Enough players want to switch — starting mode vote!");
        StartChatVote();
    }

    return Plugin_Handled;
}

// ============================================================================
// !modes — Admin only, menu-based direct switch
// ============================================================================

public Action Cmd_Modes(int client, int args)
{
    // Direct switch by name: !modes surf
    if (args > 0)
    {
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

        CancelAllVoteState();
        StartDirectSwitch(mode);
        return Plugin_Handled;
    }

    // No args — show admin mode menu
    Menu menu = new Menu(AdminModeMenuHandler);
    menu.SetTitle("Admin Mode Switch");
    menu.ExitButton = true;

    for (int i = 0; i < MODE_COUNT; i++)
    {
        char info[8];
        IntToString(i, info, sizeof(info));

        char display[64];
        if (i == g_iCurrentMode)
            Format(display, sizeof(display), "%s [CURRENT]", g_sModeNames[i]);
        else
            Format(display, sizeof(display), "%s", g_sModeNames[i]);

        menu.AddItem(info, display, (i == g_iCurrentMode) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
    }

    menu.Display(client, 30);
    return Plugin_Handled;
}

public int AdminModeMenuHandler(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        char info[8];
        menu.GetItem(item, info, sizeof(info));
        int mode = StringToInt(info);

        if (mode >= 0 && mode < MODE_COUNT && mode != g_iCurrentMode)
        {
            CancelAllVoteState();
            StartDirectSwitch(mode);
        }
    }
    else if (action == MenuAction_End)
        delete menu;
    return 0;
}

// ============================================================================
// !map / !maps — Admin map change
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
// Chat-Based Mode Vote System
// ============================================================================

public Action Timer_AutoRotationVote(Handle timer)
{
    StartChatVote();
    return Plugin_Stop;
}

void StartChatVote()
{
    if (g_bChatVoteActive)
        return;

    int playerCount = GetRealPlayerCount();
    if (playerCount == 0)
    {
        // No players — pick random mode
        int nextMode = GetRandomModeExcept(g_iCurrentMode);
        DoModeSwitch(nextMode);
        return;
    }

    g_bChatVoteActive = true;

    // Reset votes
    for (int i = 0; i < MODE_COUNT; i++)
        g_iChatVotes[i] = 0;
    for (int i = 0; i <= MAXPLAYERS; i++)
        g_bHasChatVoted[i] = false;

    // Build vote options (exclude current mode)
    g_iVoteOptionCount = 0;
    for (int i = 0; i < MODE_COUNT; i++)
    {
        if (i != g_iCurrentMode)
        {
            g_iVoteOptions[g_iVoteOptionCount] = i;
            g_iVoteOptionCount++;
        }
    }

    // Print vote header
    PrintToChatAll(" ");
    PrintToChatAll(" \x04=============================================");
    PrintToChatAll(" \x04[ospw]\x01 MODE VOTE — Type a number in chat to vote!");
    PrintToChatAll(" \x04=============================================");

    // Print options
    for (int i = 0; i < g_iVoteOptionCount; i++)
    {
        int modeIdx = g_iVoteOptions[i];
        PrintToChatAll(" \x04[ospw]\x01  \x03%d\x01 — %s", i + 1, g_sModeNames[modeIdx]);
    }

    PrintToChatAll(" ");
    PrintToChatAll(" \x04[ospw]\x01 You have \x03%d seconds\x01 to vote. Type \x031\x01-\x03%d\x01 in chat!",
        VOTE_DURATION, g_iVoteOptionCount);
    PrintToChatAll(" ");

    g_hChatVoteTimer = CreateTimer(float(VOTE_DURATION), Timer_TallyChatVotes, _, TIMER_FLAG_NO_MAPCHANGE);
}

// ============================================================================
// Chat listener — captures "1", "2", "3" etc. during active vote
// ============================================================================

public Action Cmd_Say(int client, const char[] command, int argc)
{
    if (!g_bChatVoteActive || !IsValidClient(client))
        return Plugin_Continue;

    char text[32];
    GetCmdArgString(text, sizeof(text));

    // Strip quotes
    StripQuotes(text);
    TrimString(text);

    // Check for plain number ("1", "2", etc.)
    int choice = StringToInt(text);

    // StringToInt returns 0 for non-numeric, but "0" is also 0
    // We only accept 1-based choices, so 0 is always invalid
    if (choice < 1 || choice > g_iVoteOptionCount)
        return Plugin_Continue;

    if (g_bHasChatVoted[client])
    {
        PrintToChat(client, " \x04[ospw]\x01 You already voted!");
        return Plugin_Handled;  // Suppress the chat message
    }

    int modeIdx = g_iVoteOptions[choice - 1];
    g_iChatVotes[modeIdx]++;
    g_bHasChatVoted[client] = true;

    char name[64];
    GetClientName(client, name, sizeof(name));
    PrintToChatAll(" \x04[Vote]\x01 %s voted for \x03%s\x01 (%d)", name, g_sModeNames[modeIdx], choice);

    return Plugin_Handled;  // Suppress the number from chat
}

// ============================================================================
// Tally chat votes
// ============================================================================

public Action Timer_TallyChatVotes(Handle timer)
{
    g_hChatVoteTimer = INVALID_HANDLE;
    g_bChatVoteActive = false;

    // Find winner
    int winnerMode = -1;
    int maxVotes = 0;
    int totalVotes = 0;

    for (int i = 0; i < MODE_COUNT; i++)
    {
        totalVotes += g_iChatVotes[i];
        if (g_iChatVotes[i] > maxVotes)
        {
            maxVotes = g_iChatVotes[i];
            winnerMode = i;
        }
    }

    // No votes — pick random different mode
    if (totalVotes == 0 || winnerMode == -1)
    {
        winnerMode = GetRandomModeExcept(g_iCurrentMode);
        PrintToChatAll(" \x04[ospw]\x01 No votes cast — randomly selected \x03%s\x01!", g_sModeNames[winnerMode]);
    }
    else
    {
        // If winner is current mode (shouldn't happen since we exclude it, but safety)
        if (winnerMode == g_iCurrentMode)
        {
            g_iMapsPlayed = 0;
            PrintToChatAll(" \x04[ospw]\x01 Players voted to stay in \x03%s\x01! Rotation reset.",
                g_sModeNames[winnerMode]);

            // Reset switchmode requests
            for (int i = 0; i <= MAXPLAYERS; i++)
                g_bWantsModeSwitch[i] = false;
            g_iSwitchModeRequests = 0;
            return Plugin_Stop;
        }

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
    // Universal tips (all modes)
    PrintToChatAll(" \x04[ospw]\x01 \x03!switchmode\x01 vote to change mode | \x03!rtv\x01 vote to change map");
    PrintToChatAll(" \x04[ospw]\x01 \x03!ws !knife !gloves\x01 to set your skins!");

    // Mode-specific tips
    switch (g_iCurrentMode)
    {
        case MODE_KZ:
        {
            PrintToChatAll(" \x04[ospw]\x01 \x03!menu\x01 checkpoints | \x03!options\x01 KZ settings");
            PrintToChatAll(" \x04[ospw]\x01 \x03!start\x01 go to start | \x03!end\x01 go to end | \x03!nc\x01 noclip");
        }
        case MODE_SURF:
        {
            PrintToChatAll(" \x04[ospw]\x01 \x03!r\x01 restart | \x03!s\x01 go to start | \x03!end\x01 go to end");
            PrintToChatAll(" \x04[ospw]\x01 \x03!nc\x01 noclip | \x03!start\x01 set start pos");
        }
        case MODE_RETAKE:
        {
            PrintToChatAll(" \x04[ospw]\x01 \x03!guns\x01 to choose your weapons");
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

int GetRealPlayerCount()
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
            count++;
    }
    return count;
}

bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client));
}
