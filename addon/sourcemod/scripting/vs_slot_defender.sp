#pragma semicolon              1
#pragma newdecls               required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>


public Plugin myinfo = {
    name        = "VsSlotDefender",
    author      = "TouchMe",
    description = "",
    version     = "build0002",
    url         = "https://github.com/TouchMe-Inc/l4d2_vs_slot_defender"
};


// Team macros
#define TEAM_NONE          0
#define TEAM_SPECTATOR     1
#define TEAM_SURVIVORS     2
#define TEAM_INFECTED      3

// Configurable cvar for managing the survivor team size
ConVar g_cvarSurvivorLimit = null;  // Cvar for the survivor team size (for both teams)

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
    g_cvarSurvivorLimit = FindConVar("survivor_limit");

    // Hook into the round start event, triggered after the round starts
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

    // Hook into the player team change event (when players switch teams)
    HookEvent("player_team", Event_PlayerTeam);
}

public void Event_RoundStart(Event event, const char[] szEventName, bool bDontBroadcast)
{
    if (!InSecondHalfOfRound()) {
        CreateTimer(1.0, Timer_RestorePlayerTeam, .flags = TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
}

public Action Timer_RestorePlayerTeam(Handle timer)
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
public void Event_PlayerTeam(Event event, const char[] szEventName, bool bDontBroadcast)
{
    int iClient = GetClientOfUserId(GetEventInt(event, "userid"));

    // Check to exclude invalid or non-existing clients, as well as fake clients
    if (!iClient || !IsClientInGame(iClient) || IsFakeClient(iClient)) {
        return;
    }

    if (!GetTrieSize(g_hTeamStorage)) {
        return;
    }

    // Restore the player's team in the next frame
    RequestFrame(RestorePlayerTeam, iClient);
}

/**
 * Restores the player's team or sends them to spectator.
 * Checks if the player's team is saved, and restores it if possible.
 * If the team is full, the player is moved to the spectator team.
 *
 * @param iClient The client ID for whom the team is being restored.
 */
public void RestorePlayerTeam(int iClient)
{
    if (!IsClientInGame(iClient)) return;

    char szSteamId[32];
    GetClientAuthId(iClient, AuthId_Steam2, szSteamId, sizeof(szSteamId));

    int iSavedTeam;
    // Check if the player's team is saved
    if (!GetTrieValue(g_hTeamStorage, szSteamId, iSavedTeam)) {
        return;
    }

    if (GetClientTeam(iClient) == iSavedTeam) {
        return;
    }

    if (IsPlayerTeam(iSavedTeam) && IsTeamFull(iSavedTeam)) {
        MoveExcessPlayerToSpectator(iSavedTeam);
    }

    ChangeClientTeam(iClient, iSavedTeam);
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
        if (IsClientInGame(i) && GetClientTeam(i) == iTeam) {
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
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || GetClientTeam(i) != iTeam) continue;

        char szSteamId[32];
        GetClientAuthId(i, AuthId_Steam2, szSteamId, sizeof(szSteamId));

        int iSavedTeam;
        // Check if the player's team is saved
        if (!GetTrieValue(g_hTeamStorage, szSteamId, iSavedTeam) || iSavedTeam != iTeam) {
            ChangeClientTeam(i, TEAM_SPECTATOR);
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
    if (!InSecondHalfOfRound()) {
        return;
    }

    ClearTrie(g_hTeamStorage); // Clear previous data before saving new ones

    int iFirstTeam = AreTeamsFlipped() == true ? 2 : 1;
    int iSecondTeam = iFirstTeam == 1 ? 2 : 1;

    int iFirstTeamScore = L4D_GetTeamScore(iFirstTeam);
    int iSecondTeamScore = L4D_GetTeamScore(iSecondTeam);

    bool bFlipTeam = iFirstTeamScore < iSecondTeamScore;



    // Save the team for each player
    char szSteamId[32];

    for (int iClient = 1; iClient <= MaxClients; iClient ++)
    {
        if (!IsClientInGame(iClient) || IsFakeClient(iClient)) continue;

        GetClientAuthId(iClient, AuthId_Steam2, szSteamId, sizeof(szSteamId));

        int iTeam = GetClientTeam(iClient);

        // Save only active teams (survivors and infected)
        if (IsPlayerTeam(iTeam)) {
            SetTrieValue(g_hTeamStorage, szSteamId, bFlipTeam ? (iTeam == TEAM_SURVIVORS ? TEAM_INFECTED : TEAM_SURVIVORS) : iTeam);
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
    return GetConVarInt(g_cvarSurvivorLimit);
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
