#pragma semicolon              1
#pragma newdecls               required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>


public Plugin myinfo = {
    name        = "VsSlotDefender",
    author      = "TouchMe",
    description = "The plugin should save player teams between map changes",
    version     = "build0005",
    url         = "https://github.com/TouchMe-Inc/l4d2_vs_slot_defender"
};


// Team macros
#define TEAM_NONE          0
#define TEAM_SPECTATOR     1
#define TEAM_SURVIVORS     2
#define TEAM_INFECTED      3

/*
 * Game rule team.
 */
#define TEAM_A                  0
#define TEAM_B                  1

/**
 * Sugar.
 */
#define GetVSCampaignScore      L4D2Direct_GetVSCampaignScore
#define SetHumanSpec            L4D_SetHumanSpec
#define TakeOverBot             L4D_TakeOverBot


bool g_bRoundIsLive = false;

// Configurable cvar for managing the survivor team size
ConVar g_cvSurvivorLimit = null;  // Cvar for the survivor team size (for both teams)

// Trie for storing player teams by their SteamID
Handle g_hTeamStorage = INVALID_HANDLE;


/**
 * Called before OnPluginStart.
 * Ensures the plugin is only loaded in Left 4 Dead 2.
 */
public APLRes AskPluginLoad2(Handle myself, bool bLate, char[] sErr, int iErrLen)
{
    if (GetEngineVersion() != Engine_Left4Dead2)
    {
        strcopy(sErr, iErrLen, "Plugin only supports Left 4 Dead 2");
        return APLRes_SilentFailure;
    }

    return APLRes_Success;
}

/**
 * Plugin initialization.
 * This function is called when the plugin starts and sets up event hooks.
 */
public void OnPluginStart()
{
    // Create a Trie to store player team information
    g_hTeamStorage = CreateTrie();

    // Find the cvar for the survivor team limit
    g_cvSurvivorLimit = FindConVar("survivor_limit");

    // Hook into the round start event, triggered after the round starts
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

    // Hook into the player team change event (when players switch teams)
    HookEvent("player_team", Event_PlayerTeam);

    // Hook change team <KEY_M>.
    AddCommandListener(Listener_OnPlayerJoinTeam, "jointeam");
}

/**
 * Blocking a team change if there is a mix of teams now.
 */
Action Listener_OnPlayerJoinTeam(int iClient, const char[] sCmd, int iArgs)
{
    if (!GetTrieSize(g_hTeamStorage)) {
        return Plugin_Continue;
    }

    char szSteamId[32];
    GetClientAuthId(iClient, AuthId_Steam2, szSteamId, sizeof(szSteamId));

    int iSavedTeam;
    // Check if the player's team is saved
    if (!GetTrieValue(g_hTeamStorage, szSteamId, iSavedTeam)) {
        return Plugin_Continue;
    }

    return Plugin_Stop;
}

void Event_RoundStart(Event event, const char[] szEventName, bool bDontBroadcast)
{
    g_bRoundIsLive = true;

    if (!InSecondHalfOfRound()) {
        CreateTimer(1.0, Timer_ClearTeamStorage, .flags = TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
}

Action Timer_ClearTeamStorage(Handle timer)
{
    if (!IsAnyPlayerLoading())
    {
        ClearTrie(g_hTeamStorage); // Clean up the trie when no players are loading
        return Plugin_Stop;
    }

    return Plugin_Continue;
}

/**
 * Handles the player team change event.
 * This is triggered when a player changes teams. It requests restoring their previous team.
 */
void Event_PlayerTeam(Event event, const char[] szEventName, bool bDontBroadcast)
{
    int iClient = GetClientOfUserId(GetEventInt(event, "userid"));

    // Check to exclude invalid or non-existing clients, as well as fake clients
    if (!iClient || !IsClientInGame(iClient) || IsFakeClient(iClient)) {
        return;
    }

    if (!g_bRoundIsLive) {
        return;
    }

    if (!GetTrieSize(g_hTeamStorage)) {
        return;
    }

    // Restore the player's team in the next frame
    CreateTimer(0.05, Timer_RestorePlayerTeam, iClient, .flags = TIMER_FLAG_NO_MAPCHANGE);
}

/**
 * Restores the player's team or sends them to spectator.
 * Checks if the player's team is saved, and restores it if possible.
 * If the team is full, the player is moved to the spectator team.
 *
 * @param iClient The client ID for whom the team is being restored.
 */
Action Timer_RestorePlayerTeam(Handle hTimer, int iClient)
{
    if (!IsClientInGame(iClient)) return Plugin_Stop;

    char szSteamId[32];
    GetClientAuthId(iClient, AuthId_Steam2, szSteamId, sizeof(szSteamId));

    int iSavedTeam;
    // Check if the player's team is saved
    if (!GetTrieValue(g_hTeamStorage, szSteamId, iSavedTeam)) {
        return Plugin_Stop;
    }

    if (GetClientTeam(iClient) == iSavedTeam) {
        return Plugin_Stop;
    }

    if (IsPlayerTeam(iSavedTeam) && IsTeamFull(iSavedTeam)) {
        MoveExcessPlayerToSpectator(iSavedTeam);
    }

    SetupClientTeam(iClient, iSavedTeam);

    return Plugin_Stop;
}

/**
 * Checks if a team is full.
 * Verifies whether the team size has reached the maximum limit.
 *
 * @param iTeam The team to check.
 * @return Returns true if the team is full, false otherwise.
 */
bool IsTeamFull(int iTeam)
{
    int iCount = 0;

    // Count how many players are in the given team
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == iTeam) {
            iCount++;
        }
    }

    return iCount >= GetMaxTeamSize();
}

/**
 * Moves excess players to the spectator team.
 * Finds the extra player in the team and moves them to spectator if the team is full.
 *
 * @param iTeam The team to check for excess players.
 */
int MoveExcessPlayerToSpectator(int iTeam)
{
    // Iterate through all players and find the excess one
    char szSteamId[32];

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != iTeam) continue;

        GetClientAuthId(i, AuthId_Steam2, szSteamId, sizeof(szSteamId));

        int iSavedTeam;
        // Check if the player's team is saved
        if (!GetTrieValue(g_hTeamStorage, szSteamId, iSavedTeam) || iSavedTeam != iTeam) {
            SetupClientTeam(i, TEAM_SPECTATOR);
            return i;
        }
    }

    return -1;
}

/**
 * Saves the teams of all players in the Trie.
 * It stores the team of each player if they are on an active team.
 */
public void L4D2_OnEndVersusModeRound_Post()
{
    g_bRoundIsLive = false;

    if (!InSecondHalfOfRound()) {
        return;
    }

    ClearTrie(g_hTeamStorage); // Clear previous data before saving new ones

    int iSurvivalTeam = AreTeamsFlipped() ? TEAM_B : TEAM_A;
    int iInfectedTeam = iSurvivalTeam == TEAM_A ? TEAM_B : TEAM_A;

    int iSurvivalScore = GetVSCampaignScore(iSurvivalTeam);
    int iInfectedScore = GetVSCampaignScore(iInfectedTeam);

    bool bSurvivorTeamWin = iInfectedScore < iSurvivalScore;

    // Save the team for each player
    char szSteamId[32];

    for (int iClient = 1; iClient <= MaxClients; iClient ++)
    {
        if (!IsClientInGame(iClient) || IsFakeClient(iClient)) continue;

        GetClientAuthId(iClient, AuthId_Steam2, szSteamId, sizeof(szSteamId));

        int iTeam = GetClientTeam(iClient);

        // Save only active teams (survivors and infected)
        if (IsPlayerTeam(iTeam)) {
            SetTrieValue(g_hTeamStorage, szSteamId, bSurvivorTeamWin ? iTeam : (iTeam == TEAM_INFECTED ? TEAM_SURVIVORS : TEAM_INFECTED));
        } else {
            SetTrieValue(g_hTeamStorage, szSteamId, TEAM_SPECTATOR);
        }
    }
}

/**
 * Retrieves the maximum team size for survivors in the game.
 *
 * @return The maximum team size for survivors (integer value).
 */
 int GetMaxTeamSize() {
    return GetConVarInt(g_cvSurvivorLimit);
}

bool IsPlayerTeam(int iTeam) {
    return iTeam == TEAM_SURVIVORS || iTeam == TEAM_INFECTED;
}

/**
 * Checks if the current round is the second half.
 *
 * @return true if it is the second half of the round, false otherwise.
 */
bool InSecondHalfOfRound() {
    return view_as<bool>(GameRules_GetProp("m_bInSecondHalfOfRound"));
}

/**
 * Checks if the teams have swapped places.
 *
 * @return true if the teams have swapped, false otherwise.
 */
bool AreTeamsFlipped() {
    return view_as<bool>(GameRules_GetProp("m_bAreTeamsFlipped"));
}

/**
 * Determine if a player is connecting.
 *
 * @return          True if there are connecting players, false otherwise.
 */
bool IsAnyPlayerLoading()
{
    for (int iClient = 1; iClient <= MaxClients; iClient ++)
    {
        if (IsClientConnected(iClient) && (!IsClientInGame(iClient) || GetClientTeam(iClient) == TEAM_NONE)) {
            return true;
        }
    }

    return false;
}

/**
 * Sets the client team.
 *
 * @param iClient           Client index.
 * @param iTeam             Client team.
 * @return                  Returns true if success.
 */
bool SetupClientTeam(int iClient, int iTeam)
{
    if (GetClientTeam(iClient) == iTeam) {
        return true;
    }

    if (iTeam == TEAM_INFECTED || iTeam == TEAM_SPECTATOR)
    {
        ChangeClientTeam(iClient, iTeam);
        return true;
    }

    int iBot = FindSurvivorBot();
    if (iTeam == TEAM_SURVIVORS && iBot != -1)
    {
        ChangeClientTeam(iClient, TEAM_NONE);
        SetHumanSpec(iBot, iClient);
        TakeOverBot(iClient);

        return true;
    }

    return false;
}

/**
 * Finds a free bot.
 *
 * @return                  Bot index, otherwise -1.
 */
int FindSurvivorBot()
{
    for (int iClient = 1; iClient <= MaxClients; iClient++)
    {
        if (!IsClientInGame(iClient)
        || !IsFakeClient(iClient)
        || !IsClientSurvivor(iClient)) {
            continue;
        }

        return iClient;
    }

    return -1;
}

/**
 * Survivor team player?
 */
bool IsClientSurvivor(int iClient) {
    return (GetClientTeam(iClient) == TEAM_SURVIVORS);
}
