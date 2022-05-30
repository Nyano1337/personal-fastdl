#include <sourcemod>
#include <ripext>
#include <system2>
#include <multicolors>
#include <shavit/mapchooser>



#pragma newdecls required
#pragma semicolon 1

#define DOMAIN "101.43.237.126:5244"
#define MAP_PATH "surf/maps/"
#define DOWNLOAD_LINK_PREFIX "http://"...DOMAIN..."/d/"...MAP_PATH

#define PER_MEGABTYES (1 << 20)

bool gB_IsDownloading = false;

StringMap gSM_LocalMaps = null;
ArrayStack gA_DownloadList = null;


Handle gH_SyncTextHud = null;

public void OnPluginStart()
{
	gH_SyncTextHud = CreateHudSynchronizer();

	gSM_LocalMaps = new StringMap();
	gA_DownloadList = new ArrayStack(ByteCountToCells(PLATFORM_MAX_PATH));

	GetLocalMaplist();

	System2_ExecuteThreaded(Init_7_Zip, "chmod -R 777 ./csgo/addons/sourcemod/data/system2/*");

	RegAdminCmd("sm_fastdl", Command_FastDLCheck, ADMFLAG_RCON, "验证本地服务器与下载站之间的地图完整性");
	/* RegAdminCmd("sm_debugdl", Command_Debug, ADMFLAG_RCON); */

	CSetPrefix("[{lightred}地图更新{default}] >> ");
}

public Action Timer_Cron(Handle timer)
{
	if(!gB_IsDownloading)
	{
		DoFastDLCheck();
	}

	return Plugin_Continue;
}

public void Init_7_Zip(bool success, const char[] command, System2ExecuteOutput output)
{
	char sOutput[4096];
	output.GetOutput(sOutput, sizeof(sOutput));

	if(strlen(sOutput) == 0)
	{
		PrintToServer("Init 7zip success!");
	}
	else
	{
		SetFailState("Init 7zip failed!!! error: %s", sOutput);
	}
}

public void OnMapStart()
{
	gSM_LocalMaps.Clear();

	GetLocalMaplist();

	CreateTimer(60.0, Timer_Cron, 0, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Command_FastDLCheck(int client, int args)
{
	DoFastDLCheck();

	return Plugin_Handled;
}

/* public Action Command_Debug(int client, int args)
{
	DownloadMapFromFastDL_BspRaw("surf_angst_go");

	return Plugin_Handled;
} */

static void GetLocalMaplist()
{
	DirectoryListing dir = OpenDirectory("./maps");
	if(dir == null)
	{
		LogError("Failed to open maps dir");

		return;
	}

	FileType type = FileType_Unknown;
	char sMap[PLATFORM_MAX_PATH];

	while(dir.GetNext(sMap, sizeof(sMap), type))
	{
		if(type != FileType_File || StrContains(sMap, ".bsp", false) == -1 || StrContains(sMap, ".bz2", false) != -1)
		{
			continue;
		}

		int end = FindCharInString(sMap, '.', true);
		sMap[end] = '\0';

		/* we have that map */
		gSM_LocalMaps.SetValue(sMap, true);
	}
}

static void DoFastDLCheck()
{
	InitDownloadList();

	HTTPRequest fastdl = new HTTPRequest("http://"... DOMAIN ..."/api/public/path");

	JSONObject json = new JSONObject();
	json.SetString("path", MAP_PATH);

	fastdl.Post(json, FastDLCheck_Callback);
	delete json;
}

public void FastDLCheck_Callback(HTTPResponse response, any value, const char[] error)
{
	if(response.Status != HTTPStatus_OK)
	{
		CPrintToChatAll("{lightred}无法查询下载站地图! 状态: %d", response.Status);

		return;
	}

	response.Data.ToFile("fastdlmaplist.json");

	JSONObject maps_root = view_as<JSONObject>(JSONObject.FromFile("fastdlmaplist.json").Get("data"));

	JSONArray maplist = view_as<JSONArray>(maps_root.Get("files"));
	delete maps_root;

	/* 遍历下载站地图的'files'键*/
	for(int i = 0; i < maplist.Length; i++)
	{
		JSONObject map = view_as<JSONObject>(maplist.Get(i));

		char sMap[PLATFORM_MAX_PATH];
		map.GetString("name", sMap, sizeof(sMap));

		int end = FindCharInString(sMap, '.', false);
		if(end != -1) /* 正常来说不会找不到'.'，除非有傻逼上传了错误格式的地图 */
		{
			sMap[end] = '\0';
			DoFastDLComparedToLocal(sMap);
		}

		delete map;
	}

	delete maplist;

	if(FileExists("fastdlmaplist.json"))
	{
		DeleteFile("fastdlmaplist.json");
	}

	/* 遍历完了就开始下载啦(非异步) */
	DownloadMapByStack();
}

static void DoFastDLComparedToLocal(const char[] map)
{
	any value;
	if(gSM_LocalMaps.GetValue(map, value)) /* 说明有这个图 */
	{
		return;
	}

	/* 没有那就去下载吧 */
	CPrintToChatAll("{darkred}缺失地图 %s, 正在进行下载...", map);

	/* 慢慢来, 别急... */
	gA_DownloadList.PushString(map);
}

static void DownloadMapByStack()
{
	/* 没有地图要下载 */
	if(gA_DownloadList.Empty)
	{
		gB_IsDownloading = false;
		Shavit_RefreshMaplist();

		return;
	}

	char sMap[160];
	gA_DownloadList.PopString(sMap, sizeof(sMap));

	DownloadMapFromFastDL(sMap);
}

static void DownloadMapFromFastDL(const char[] map)
{
	System2HTTPRequest download = new System2HTTPRequest(DownloadBspBz2FromFastDL_Callback, "%s/%s.bsp.bz2", DOWNLOAD_LINK_PREFIX, map);

	download.SetOutputFile("%s.bsp.bz2", map);
	download.SetProgressCallback(DownloadMapFromFastDL_ProgressCallback);
	download.GET();

	CPrintToChatAll("{yellow}正在下载地图压缩包 {orchid}%s", map);
}

public void DownloadBspBz2FromFastDL_Callback(bool success, const char[] error, System2HTTPRequest request, System2HTTPResponse response, HTTPRequestMethod method)
{
	char sURL[512];
	request.GetURL(sURL, sizeof(sURL));

	char sMap[160];
	int start = FindCharInString(sURL, '/', true) + 1;
	StrCat(sMap, sizeof(sMap), sURL[start]);

	int end = FindCharInString(sMap, '.');

	if(response.ContentLength > 100)
	{
		if(System2_Extract(OnDownloadBspBz2Success_Callback, sMap, "./maps", _, true))
		{
			sMap[end] = '\0';
			CPrintToChatAll("{green}地图: %s 已下载并解压成功", sMap);

			/* we have that map */
			gSM_LocalMaps.SetValue(sMap, true);

			char sThreadCommand[CMD_MAX_LENGTH];
			FormatEx(sThreadCommand, sizeof(sThreadCommand), "rm -rf ./csgo/%s.bsp.bz2", sMap);
			System2_ExecuteThreaded(ContinueDownload, sThreadCommand);
		}
		else
		{
			/* 停止下载吧 */
			sMap[end] = '\0';
			CPrintToChatAll("{darkred}地图: %s 下载成功, 但解压失败! 请确认服务器剩余硬盘空间!!!", sMap);
		}
	}
	else
	{
		sMap[end] = '\0';
		DownloadMapFromFastDL_BspRaw(sMap);
	}
}

public void OnDownloadBspBz2Success_Callback(bool success, const char[] command, System2ExecuteOutput output)
{
	/* Do nothing */
}

public void ContinueDownload(bool success, const char[] command, System2ExecuteOutput output)
{
	/* 非异步, 继续下载! */
	DownloadMapByStack();
}

static void DownloadMapFromFastDL_BspRaw(const char[] map)
{
	System2HTTPRequest download = new System2HTTPRequest(DownloadBspRawFromFastDL_ProgressCallback, "%s/%s.bsp", DOWNLOAD_LINK_PREFIX, map);

	download.SetOutputFile("%s.bsp", map);
	download.SetProgressCallback(DownloadMapFromFastDL_ProgressCallback);
	download.GET();

	CPrintToChatAll("{yellow}该地图大于150M, 正在下载bsp {orchid}%s", map);
}

public void DownloadBspRawFromFastDL_ProgressCallback(bool success, const char[] error, System2HTTPRequest request, System2HTTPResponse response, HTTPRequestMethod method)
{
	char sURL[512];
	request.GetURL(sURL, sizeof(sURL));

	char sMap[160];
	int start = FindCharInString(sURL, '/', true) + 1;
	StrCat(sMap, sizeof(sMap), sURL[start]);

	if(response.ContentLength > 100)
	{
		char sThreadCommand[CMD_MAX_LENGTH];
		FormatEx(sThreadCommand, sizeof(sThreadCommand), "mv ./csgo/%s ./csgo/maps/", sMap);
		System2_ExecuteThreaded(OnDownloadBspRawSuccess_Callback, sThreadCommand);

		/* we have that map */
		int end = FindCharInString(sMap, '.');
		sMap[end] = '\0';
		gSM_LocalMaps.SetValue(sMap, true);

		CPrintToChatAll("{green}地图: %s 已下载且合并成功", sMap);
	}
	else
	{
		CPrintToChatAll("{darkred}地图 %s 下载失败, 怎么回事? 状态: %d", sMap, response.StatusCode);

		/* 停止下载! */
		LogError("地图下载失败! 请检查硬盘空间或其他原因!!!");
	}
}

public void OnDownloadBspRawSuccess_Callback(bool success, const char[] command, System2ExecuteOutput output)
{
	/* 非异步, 继续下载! */
	DownloadMapByStack();
}

public void DownloadMapFromFastDL_ProgressCallback(System2HTTPRequest request, int dlTotal, int dlNow, int ulTotal, int ulNow)
{
	if(dlTotal <= (1 << 10)) /* 1024 */
	{
		return;
	}

	gB_IsDownloading = true;

	float now = float(dlNow) / PER_MEGABTYES;
	float total = float(dlTotal) / PER_MEGABTYES;

	SetHudTextParamsEx(0.0, 0.925, 1.0, {255, 255, 255, 255}, _, 1, 1.0, 0.0, 0.0);

	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsValidClient(i) && !IsFakeClient(i))
		{
			ShowSyncHudText(i, gH_SyncTextHud, 
				"下载进度: %.1fM / %.1fM (%.1f%s)", 
				now,
				total,
				(now / total) * 100,
				"%");
		}
	}
}

static void InitDownloadList()
{
	delete gA_DownloadList;
	gA_DownloadList = new ArrayStack(ByteCountToCells(PLATFORM_MAX_PATH));
}

stock bool IsValidClient(int client, bool bAlive = false)
{
	return (client >= 1 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client) && !IsClientSourceTV(client) && (!bAlive || IsPlayerAlive(client)));
}
