unit theme_controller;

{$mode objfpc}{$H+}

interface

uses
  {$if fpc_fullversion >= 20701}
    ghashmap,
  {$else fpc_fullversion >= 20701}
    fgl,
  {$endif fpc_fullversion >= 20701}
  fpcgi, fpTemplate, fphttp, fpWeb, HTTPDefs, dateutils,
  RegExpr,
  common, fastplaz_handler, sqldb,
  Classes, SysUtils;

const
  __FOREACH_START = '{foreach([\.\$A-Za-z= ]+)}';
  __FOREACH_END = '\{/foreach[\.\$A-Za-z0-9= ]+}';

type

  // based on qtemplate
  {$if fpc_fullversion >= 20701}
    { TStringHash }
    TStringHash = class
      class function hash(s: String; n: Integer): Integer;
    end;
    generic TStringHashMap<T> = class(specialize THashMap<String,T,TStringHash>) end;
  {$else fpc_fullversion >= 20701}
    generic TStringHashMap<T> = class(specialize TFPGMap<String,T>) end;
  {$endif fpc_fullversion >= 20701}

  TAssignVarMap = specialize TStringHashMap<Pointer>;
  TTagCallbackMap = specialize TStringHashMap<TTagCallback>; // based on qtemplate


  { THTMLHead }

  THTMLHead = class
  private
  public
    JS, CSS, Meta : TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure AddJS( const FileName:string);
    procedure AddCSS( const FileName:string; const Media:string='all');
    procedure AddMeta( const Name:string; const Content:string; const MetaType:string = 'name');
  end;

  { TThemeUtil }

  TThemeUtil = class
  private
    FBaseURL : string;
    FEndDelimiter, FStartDelimiter, FParamValueSeparator: string;
    FThemeName, FThemeExtension: string;
    FHTMLHead : THTMLHead;
    FTrimForce: boolean;
    FTrimWhiteSpace: boolean;
    function GetAssignVar(const TagName: String): Pointer;
    function GetBaseURL: string;
    function GetThemeName: string;
    procedure SetAssignVar(const TagName: String; AValue: Pointer);
    procedure SetThemeName(AValue: string);
    procedure SetTrimForce(AValue: boolean);
    procedure SetTrimWhiteSpace(AValue: boolean);
    function _GetModuleName(Arequest: TRequest): string;

    function FilterOutput( Content, Filter:string):string;
    function BlockController( const ModuleName:string; const FunctionName:string; Parameter:TStrings):string;
    function FindModule(ModuleClass: TCustomHTTPModuleClass): TCustomHTTPModule;
    function getDebugInfo( DebugType:string):string;
    function DoTrimWhiteSpace(const Content:string;ForceTrim:boolean=false):string;

    //- cache
    function getCacheFileName: string;
    function isCacheExpired: boolean;
    function LoadCache: string;
    procedure SaveCache(Content: string);

    //-- foreach
    function ForeachProcessor( TagProcessor: TReplaceTagEvent; Content:string):string;
    function ForeachProcessor_Table( TagProcessor: TReplaceTagEvent; KeyName, Content: string):string;
    procedure ForeachProcessor_Table_TagController(Sender: TObject; const TagString: string;
      TagParams: TStringList; Out ReplaceText: string);
  public
    constructor Create;
    destructor Destroy; override;
    property ThemeName: string read GetThemeName write SetThemeName;
    property Extension: string read FThemeExtension write FThemeExtension;
    property StartDelimiter: string read FStartDelimiter write FStartDelimiter;
    property EndDelimiter: string read FEndDelimiter write FEndDelimiter;
    property BaseURL : string Read GetBaseURL;
    function GetVersionInfo():boolean;

    procedure TagController(Sender: TObject; const TagString:String; TagParams: TStringList; Out ReplaceText: String);

    property AssignVar[const TagName: String]: Pointer read GetAssignVar write SetAssignVar;

    procedure Assign(const KeyName: string; const Address: pointer = nil);
    procedure Assign(const KeyName: string; Value:string);
    function Render(TagProcessorAddress: TReplaceTagEvent=nil; TemplateFile: string = '';
      Cache: boolean = False; SubModule:boolean =false): string;
    function RenderFromContent(TagProcessorAddress: TReplaceTagEvent; Content: string;
      TemplateFile: string = ''): string;

    property TrimWhiteSpace:boolean read FTrimWhiteSpace write SetTrimWhiteSpace;
    property TrimForce:boolean read FTrimForce write SetTrimForce;
    procedure AddJS( const FileName:string);
    procedure AddCSS( const FileName:string; const Media:string='all');
    procedure AddMeta( const Name:string; const Content:string; const MetaType:string = 'name');
  end;

var
  ThemeUtil: TThemeUtil;
  ___TagCallbackMap: TTagCallbackMap;

implementation

uses logutil_lib, language_lib, versioninfo_lib, html_lib,
  initialize_controller;

var
  FAssignVarMap : TAssignVarMap;
  FAssignVarStringMap : TStringList;
  ForeachTable_Keyname,
  ForeachTable_Itemname : string;
  FTagAssign_Variable : TStringList;

{ THTMLHead }

constructor THTMLHead.Create;
begin
  JS := TStringList.Create;
  CSS := TStringList.Create;
  Meta := TStringList.Create;
end;

destructor THTMLHead.Destroy;
begin
  FreeAndNil(Meta);
  FreeAndNil(CSS);
  FreeAndNil(JS);
  inherited Destroy;
end;

procedure THTMLHead.AddJS(const FileName: string);
begin
  if FileName='' then Exit;
  JS.Add('<script type="text/javascript" src="'+FileName+'"></script>');
end;

procedure THTMLHead.AddCSS(const FileName: string; const Media: string);
begin
  if FileName='' then Exit;
  CSS.Add('<link rel="stylesheet" href="'+FileName+'" type="text/css" media="'+Media+'" />');
end;

procedure THTMLHead.AddMeta(const Name: string; const Content: string;
  const MetaType: string);
begin
  if Name='' then Exit;
  Meta.Add('<meta '+MetaType+'="'+Name+'" content="'+Content+'" />');
end;

{ TThemeUtil }

function TThemeUtil.GetThemeName: string;
begin
  if FThemeName = '' then
  begin
    FThemeName := Config.GetValue(_SYSTEM_THEME, 'default');
  end;
  Result := FThemeName;
end;

function TThemeUtil.GetAssignVar(const TagName: String): Pointer;
begin
  try
    Result := FAssignVarMap[TagName];
  except
    Result := nil;
  end;
end;

function TThemeUtil.GetBaseURL: string;
begin
  if FBaseURL = '' then begin
    FBaseURL:= Config.GetValue( _SYSTEM_BASEURL, '');
    if FBaseURL = '' then begin
      FBaseURL:= 'http://'+GetEnvironmentVariable('SERVER_NAME');
    end;
  end;
  Result := FBaseURL;
end;

procedure TThemeUtil.SetAssignVar(const TagName: String; AValue: Pointer);
begin
  FAssignVarMap[TagName] := AValue;
end;

procedure TThemeUtil.Assign(const KeyName: string; const Address: pointer);
begin
  if not Assigned(Address) then
    Exit;
  try
    FAssignVarMap[KeyName] := Address;
    //x := TSQLQuery( FAssignVarMap[KeyName]^).SQL.Text);
  except
    on e: Exception do
      die(e.Message + ' when "assign" variable "' + KeyName + '"');
  end;
end;

procedure TThemeUtil.Assign(const KeyName: string; Value: string);
begin
  FAssignVarStringMap.Values[KeyName] := Value;
end;

procedure TThemeUtil.SetThemeName(AValue: string);
begin
  FThemeName := AValue;
end;

procedure TThemeUtil.SetTrimForce(AValue: boolean);
begin
  if FTrimForce=AValue then Exit;
  FTrimForce:=AValue;
end;

procedure TThemeUtil.SetTrimWhiteSpace(AValue: boolean);
begin
  if FTrimWhiteSpace=AValue then Exit;
  FTrimWhiteSpace:=AValue;
end;

function TThemeUtil._GetModuleName(Arequest: TRequest): string;

  function GetDefaultModuleName: string;
  begin
    if (Application.DefaultModuleName <> '') then
      Result := Application.DefaultModuleName
    else if (ModuleFactory.Count = 1) then
      Result := ModuleFactory[0].ModuleName;
  end;

var
  S: string;
  I: integer;
begin
  Result := ARequest.QueryFields.Values[Application.ModuleVariable];
  if (Result = '') then
  begin
    S := ARequest.PathInfo;
    if (Length(S) > 0) and (S[1] = '/') then
      Delete(S, 1, 1);                      //Delete the leading '/' if exists
    I := Length(S);
    if (I > 0) and (S[I] = '/') then
      Delete(S, I, 1);                      //Delete the trailing '/' if exists
    I := Pos('/', S);
    if I > 0 then
      S := Copy(s, 1, i - 1);
    //if (I>0) or Application.PreferModuleName then
    //  Result:=ARequest.GetNextPathInfo;
    Result := S;
  end;
  if (Result = '') then
  begin
    if not Application.AllowDefaultModule then
      raise EFPWebError.Create(__(__ErrNoModuleNameForRequest));
    Result := GetDefaultModuleName;
  end;

end;

function TThemeUtil.FilterOutput(Content, Filter: string): string;
begin
  Result := Content;
  if Filter = '' then
    Exit;
  case Filter of
    'nl2br' : begin
      Result := StringReplace( Content, #13#10, '<br>', [rfReplaceAll]);
    end;
    'uppercase' : begin
      Result := UpperCase( Content);
    end;
    'lowercae' : begin
      Result := LowerCase( Content);
    end;
    'moreless' : begin
      //Result := MoreLess(Content);
    end;
  end;
end;

function TThemeUtil.BlockController(const ModuleName: string;
  const FunctionName: string; Parameter: TStrings): string;
var
  m  : TCustomHTTPModule;
  mi : TModuleItem;
  mc : TCustomHTTPModuleClass;
  f,
  StringResult : string;
  str : TStringList;
  i : integer;
begin
  mi := ModuleFactory.FindModule( ModuleName);
  if mi = nil then begin
    Result := EchoError( __Err_Theme_Modul_NotFond, [ModuleName]);
    Exit;
  end;
  //i := ModuleFactory.IndexOfModule( ModuleName);
  mc := mi.ModuleClass;
  m:=FindModule(mc);
  if m = nil then begin
    m:=mc.CreateNew(nil);
  end else begin
  end;

  // if cache, load from cache
  if (Parameter.Values['cache']='1') or (Parameter.Values['cache']='true') then begin
    f := ExtractFileDir( Application.ExeName) + '/' + AppData.temp_dir + '/cache/' + ModuleName + '-' + FunctionName + '.html';
    if FileExists( f) then begin

      i := HoursBetween( FileDateToDateTime( FileAge( f)), now);
      if i = 0 then begin  // cache : 1 hour
        str := TStringList.Create;
        str.LoadFromFile( f);
        Result := str.Text;
        FreeAndNil( str);
        Exit;
      end;
    end;
  end;

  // OnBlockController
  if TMyCustomWebModule(m).OnBlockController <> nil then begin
    TMyCustomWebModule(m).OnBlockController( Self, FunctionName, Parameter, StringResult);
    Result := StringResult;
  end;

  //-- if cache, save to cache
  if (Parameter.Values['cache']='1') or (Parameter.Values['cache']='true') then begin
    if not DirectoryExists( ExtractFileDir( f)) then
      MkDir( ExtractFileDir( f));
    str := TStringList.Create;
    str.Text:= StringResult;
    str.SaveToFile( f);
    FreeAndNil( str);
  end;
end;

function TThemeUtil.FindModule(ModuleClass: TCustomHTTPModuleClass
  ): TCustomHTTPModule;
Var
  i : Integer;
begin
  i:=Application.ComponentCount-1;
  While (i>=0) and (Not ((Application.Components[i] is ModuleClass) and (TCustomHTTPModule(Application.Components[i]).Kind<>wkOneShot))) do
    Dec(i);
  if (i>=0) then
    Result:=Application.Components[i] as TCustomHTTPModule
  else
    Result:=Nil;
end;

function TThemeUtil.getDebugInfo(DebugType: string): string;
var
  i:integer;
  lst : TStrings;
begin
  case DebugType of
    'sql': begin
      Result := '<div class="debug"><table class="debug">';
      for i:=0 to _DebugInfo.Count-1 do begin
        lst := Explode( StringReplace( _DebugInfo[i], #9#9#9, '<br>', [rfReplaceAll]), '||');
        Result := Result + '<tr>';
        Result := Result + '<td>' + lst[2] + '</td>';
        Result := Result + '<td>' + lst[1] + '</td>';
        Result := Result + '</tr>';
        FreeAndNil(lst);
      end;
      Result := Result + '</table></div>';
    end;
    'time' : begin
      _StopTime:= _GetTickCount;
      _ElapsedTime:= _StopTime - _StartTime;
      Result := i2s( _ElapsedTime) + 'ms';
    end;
  end;
end;

function TThemeUtil.GetVersionInfo: boolean;
begin
  if VersionInfo.FullVersion = '' then
  begin
    try
      with TVersionInfo.Create do
      begin
        Load( HINSTANCE);
        VersionInfo.Major        := FixedInfo.FileVersion[0];
        VersionInfo.Minor        := FixedInfo.FileVersion[1];
        VersionInfo.Revision     := FixedInfo.FileVersion[2];
        VersionInfo.BuldNumber   := FixedInfo.FileVersion[3];

        VersionInfo.Version  :=
          i2s( VersionInfo.Major) + '.' +
          i2s( VersionInfo.Minor) + '.' +
          i2s( VersionInfo.Revision);

        VersionInfo.FullVersion  :=
          i2s( VersionInfo.Major) + '.' +
          i2s( VersionInfo.Minor) + '.' +
          i2s( VersionInfo.Revision) + ' (build ' +
          i2s( VersionInfo.BuldNumber) + ')';
        Free;
      end;
      Result:=True;
    except
      VersionInfo.FullVersion := '-';
      Result:= False;
    end;
  end;
end;

function TThemeUtil.getCacheFileName: string;
var
  pathinfo: string;
begin
  pathinfo := copy(Application.Request.PathInfo, 1,
    length(Application.Request.PathInfo) - 1);
  if pathinfo = '' then
    pathinfo := Application.Request.QueryString;
  if pathinfo = '' then
    pathinfo := 'home';
  if pathinfo[1] = '/' then
    pathinfo := copy(pathinfo, 2, length(pathinfo) - 1);
  Result := ExtractFileDir(Application.ExeName) + '/' + AppData.temp_dir +
    '/cache/' + _GetModuleName(Application.Request) + '/' + ReplaceAll(
    pathinfo, ['?', '&', '=', '/'], ['-', '-', '-', '-']) + '-' + LANG + '.html';
end;

function TThemeUtil.isCacheExpired: boolean;
begin
  if HoursBetween(FileDateToDateTime(FileAge(getCacheFileName)), now) > 0 then
    Result := True
  else
    Result := False;
end;

function TThemeUtil.LoadCache: string;
var
  f: string;
begin
  Result:='';
  if AppData.cache_type = 'file' then
  begin
    f := getCacheFileName;
    if FileExists(f) and not isCacheExpired then
    begin
      try
        with TStringList.Create do
        begin
          LoadFromFile(f);
          Result := Text;
          Free;
        end;
      except
      end;
    end;
  end; //-- if AppData.cache_type = 'file'
end;

procedure TThemeUtil.SaveCache(Content: string);
var
  f: string;
begin
  if AppData.cache_type = 'file' then
  begin
    f := getCacheFileName;
    try
      if not DirectoryExists(ExtractFileDir(f)) then
        MkDir(ExtractFileDir(f));
      with TStringList.Create do
      begin
        Text := Content;
        SaveToFile(f);
        Free;
      end;
    except
      on E: Exception do
      begin
        if AppData.debug then
        begin
          _DebugInfo.Add(e.Message);
          LogUtil.add(e.Message);
        end;
      end;
    end;
  end;//- if AppData.cache_type = 'file' then
end;

function TThemeUtil.ForeachProcessor(TagProcessor: TReplaceTagEvent;
  Content: string): string;
var
  parameter : TStrings;
  html : string;
begin
  Result := Content;
  with TRegExpr.Create do
  begin
    Expression := Format('%s(.*?)%s', [ __FOREACH_START, __FOREACH_END]);
    if Exec( Content) then
    begin
      parameter := Explode( Match[1], ' ');
      ForeachTable_Keyname  := parameter.Values['from'];
      ForeachTable_Itemname := parameter.Values['item'];
      case parameter.Values['type'] of
        '' : begin
          die( 'field "type" is not define in "foreach ' + Match[1] + '"');
        end;
        'table' : begin
          html := ForeachProcessor_Table(TagProcessor, parameter.Values['from'], Match[2]);
        end;
        'array' : begin
          die( 'foreach array still not implemented');
        end;
      end;

      html := StringReplace( Content, Match[0], html, [rfReplaceAll]);

      //** call parent tag-controller

      ForeachTable_Keyname := '';
      ForeachTable_Itemname:= '';
      FreeAndNil( parameter);
      Result := html;
    end;
    Free;
  end;
end;

function TThemeUtil.ForeachProcessor_Table(TagProcessor: TReplaceTagEvent;
  KeyName, Content: string): string;
var
  html, tmp : string;
  template_engine : TFPTemplate;
begin
  if ( AssignVar[KeyName] = nil) then
  begin
    Exit;
  end;

  html := '';
  while not TSQLQuery( FAssignVarMap[KeyName]^).EOF do
  begin

    tmp := RenderFromContent(@TagController, Content);

    template_engine := TFPTemplate.Create;
    template_engine.Template := tmp;
    template_engine.AllowTagParams := True;
    template_engine.StartDelimiter := FStartDelimiter;
    template_engine.EndDelimiter := FEndDelimiter;
    template_engine.ParamValueSeparator := '=';
    template_engine.OnReplaceTag := @ForeachProcessor_Table_TagController;
    html := html + template_engine.GetContent;
    FreeAndNil(template_engine);

    html := RenderFromContent(@TagController, html);

    TSQLQuery( FAssignVarMap[KeyName]^).Next;
  end;
  Result := html;
end;

procedure TThemeUtil.ForeachProcessor_Table_TagController(Sender: TObject;
  const TagString: string; TagParams: TStringList; out ReplaceText: string);
var
  tagstring_custom : TStringList;
begin
  if ForeachTable_Keyname = '' then
    Exit;
  tagstring_custom := ExplodeTags( TagString);
  ReplaceText := FStartDelimiter +  TagString + FEndDelimiter;
  if tagstring_custom[0] <> ForeachTable_Itemname then
  begin
    FreeAndNil( tagstring_custom);
    Exit;
  end;
  if tagstring_custom.Values['assignto'] <> '' then
  begin
    FTagAssign_Variable.Values[tagstring_custom.Values['assignto']]:='s|'
      + TSQLQuery( FAssignVarMap[ForeachTable_Keyname]^).FieldByName(tagstring_custom.Values['index']).AsString;
  end;
  if tagstring_custom.Values['addassignto'] <> '' then
  begin
    if FTagAssign_Variable.Values[tagstring_custom.Values['addassignto']] = '' then
    begin
      FTagAssign_Variable.Values[tagstring_custom.Values['addassignto']]:='s|'
        + TSQLQuery( FAssignVarMap[ForeachTable_Keyname]^).FieldByName(tagstring_custom.Values['index']).AsString;
    end
    else
    begin
      FTagAssign_Variable.Values[tagstring_custom.Values['addassignto']]:=
        FTagAssign_Variable.Values[tagstring_custom.Values['addassignto']]
        + TSQLQuery( FAssignVarMap[ForeachTable_Keyname]^).FieldByName(tagstring_custom.Values['index']).AsString;
    end;
  end;
  if tagstring_custom.Values['dateformat'] <> '' then
  begin
    ReplaceText:= FormatDateTime( tagstring_custom.Values['dateformat'],
      TSQLQuery( FAssignVarMap[ForeachTable_Keyname]^).FieldByName(tagstring_custom.Values['index']).AsDateTime
    );
  end
  else
    ReplaceText:= TSQLQuery( FAssignVarMap[ForeachTable_Keyname]^).FieldByName(tagstring_custom.Values['index']).AsString;
  FreeAndNil( tagstring_custom);
end;

constructor TThemeUtil.Create;
begin
  FThemeExtension := '.html';
  FStartDelimiter := '{';
  FEndDelimiter := '}';
  FParamValueSeparator := '=';
  FTrimWhiteSpace := True;
  FTrimForce := False;
  FAssignVarMap := TAssignVarMap.Create;
  FAssignVarStringMap := TStringList.Create;
  FTagAssign_Variable := TStringList.Create;
  FHTMLHead := THTMLHead.Create;
end;

destructor TThemeUtil.Destroy;
begin
  FreeAndNil(FHTMLHead);
  FreeAndNil(FTagAssign_Variable);
  FreeAndNil(FAssignVarStringMap);
  FreeAndNil(FAssignVarMap);
  inherited Destroy;
end;

procedure TThemeUtil.TagController(Sender: TObject; const TagString: String;
  TagParams: TStringList; out ReplaceText: String);
var
  s, tagname : string;
  tagstring_custom : TStringList;
begin
  tagstring_custom := ExplodeTags( TagString);

  // check from AssignVar
  if tagstring_custom.Values['index']<>'' then
  begin
    if ThemeUtil.AssignVar[tagstring_custom[0]] <> Nil then
    begin
      try
        if tagstring_custom.Values['dateformat'] <> '' then
        begin
          ReplaceText:= FormatDateTime( tagstring_custom.Values['dateformat'],
            TSQLQuery(ThemeUtil.AssignVar[tagstring_custom[0]]^).FieldByName(tagstring_custom.Values['index']).AsDateTime
          );
        end
        else
          ReplaceText:= TSQLQuery(ThemeUtil.AssignVar[tagstring_custom[0]]^).FieldByName(tagstring_custom.Values['index']).AsString;
      except
        ReplaceText:='----';
      end;
      ReplaceText:= FilterOutput( ReplaceText, tagstring_custom.Values['filter']);
      FreeAndNil(tagstring_custom);
      Exit;
    end;
  end;
  // check from AssignVar - end

  ReplaceText := ThemeUtil.StartDelimiter +  TagString + ThemeUtil.EndDelimiter;
  if tagstring_custom.Count = 0 then Begin ReplaceText:= '[]'; Exit; End;
  tagname := tagstring_custom[0];
  case tagname of
    '$title' : begin
      ReplaceText:= AppData.sitename;
      end;
    '$baseurl' : begin
      ReplaceText:= BaseURL;
      end;
    '$theme' : begin
      ReplaceText:= ThemeName;
      end;
    '$themepath' : begin
      ReplaceText:= 'themes/' + ThemeUtil.ThemeName;
      end;
    '$themefullpath' : begin
      ReplaceText:= Config.GetValue( _SYSTEM_BASEURL, '');
      if ReplaceText = '' then begin
        ReplaceText:= 'http://'+GetEnvironmentVariable('SERVER_NAME');
      end;
      ReplaceText:= ReplaceText + '/themes/' + ThemeUtil.ThemeName;
      end;
    '$version' : begin
      GetVersionInfo();
      ReplaceText:= VersionInfo.FullVersion;
    end;
    '$env' : begin
      if tagstring_custom.Values['key'] <> '' then
        ReplaceText:=Application.EnvironmentVariable[tagstring_custom.Values['key']];
    end;
    'assign' : begin
      //s| <<-- prepare for variable type
      FTagAssign_Variable.Values[ tagstring_custom.Values['var']] := 's|'+tagstring_custom.Values['value'];
      ReplaceText:='';
    end;
    'assignadd' : begin
      s := FTagAssign_Variable.Values[ tagstring_custom.Values['var']];
      if s = ''
      then
        FTagAssign_Variable.Values[ tagstring_custom.Values['var']] := 's|'+tagstring_custom.Values['value']
      else
        FTagAssign_Variable.Values[ tagstring_custom.Values['var']] := s+tagstring_custom.Values['value'];
      ReplaceText:='';
    end;
    'value' : begin
      ReplaceText:=FTagAssign_Variable.Values[ tagstring_custom.Values['var']];
      ReplaceText:=Copy(ReplaceText,3,Length(ReplaceText)-2);
    end;
    'include' : begin
      ReplaceText:= ThemeUtil.Render( @TagController, tagstring_custom.Values['file'], false, true);;
      end;
    'block' : begin
      ReplaceText:= BlockController( tagstring_custom.Values['mod'], tagstring_custom.Values['func'], tagstring_custom);
      end;
    'text' : begin
      ReplaceText:= BlockController( tagstring_custom.Values['mod'], tagstring_custom.Values['func'], tagstring_custom);
      end;
    'debug' : begin
      ReplaceText:= getDebugInfo( tagstring_custom.Values['type']);
    end;
    'gt' : begin
      ReplaceText:= __(tagstring_custom.Values['text']);
    end;
  end;

  {$if fpc_fullversion >= 20701}
  if FTagMap.Contains(tagname) then begin
  {$else fpc_fullversion >= 20701}
  if ___TagCallbackMap.IndexOf(tagname) >= 0 then begin
  {$endif fpc_fullversion >= 20701}
    ReplaceText := ___TagCallbackMap[tagname](TagString,tagstring_custom);
  end;

  if FAssignVarStringMap.IndexOfName(TagString) <> -1 then
    ReplaceText:=FAssignVarStringMap.Values[TagString];

  ReplaceText:= FilterOutput( ReplaceText, tagstring_custom.Values['filter']);
  FreeAndNil( tagstring_custom);
end;

function TThemeUtil.Render(TagProcessorAddress: TReplaceTagEvent;
  TemplateFile: string; Cache: boolean; SubModule: boolean): string;
var
  template_filename, _ext, module_active: string;
  template_engine: TFPTemplate;
begin
  if Cache then
  begin
    Result := LoadCache;
    if Result <> '' then
    begin
      Result := Result+'<!-- '+getDebugInfo('time')+'-->';
      Exit;
    end;
  end;

  if not DirectoryExists('themes') then
  begin
    Result := Result + Format( __(__Err_App_Init), [Application.EnvironmentVariable['REQUEST_URI']+'/initialize/']);
    Exit;
  end;

  if TemplateFile <> '' then
  begin
    TemplateFile := StringReplace(TemplateFile, '"', '', [rfReplaceAll]);
    TemplateFile := StringReplace(TemplateFile, '''', '', [rfReplaceAll]);
    _ext := FThemeExtension;
    if ExtractFileExt(TemplateFile) <> '' then
      _ext := '';
    template_filename := 'themes/' + ThemeName + '/templates/' + TemplateFile + _ext;

    if not FileExists(template_filename) then
    begin
      Result := EchoError( __(__Err_Theme_Not_Exists), [TemplateFile, ThemeName]);
      Exit;
    end;
  end
  else
  begin
    module_active := _GetModuleName(Application.Request);
    template_filename := Application.Request.QueryFields.Values['act'];
    if template_filename = '' then
      template_filename := 'master';
    template_filename := 'themes/' + ThemeName + '/templates/modules/' + module_active +
      '/' + template_filename + FThemeExtension;
    if not FileExists(template_filename) then
      template_filename := 'themes/' + ThemeName + '/templates/modules/' + module_active +
        '/master' + FThemeExtension;
    if not FileExists(template_filename) then
      template_filename := 'themes/' + ThemeName + '/templates/master' + FThemeExtension;
  end;


  try
    template_engine := TFPTemplate.Create;
    template_engine.FileName := template_filename;
    template_engine.AllowTagParams := True;
    template_engine.StartDelimiter := FStartDelimiter;
    template_engine.EndDelimiter := FEndDelimiter;
    template_engine.ParamValueSeparator := FParamValueSeparator;
    if TagProcessorAddress = nil then
      template_engine.OnReplaceTag := @TagController
    else
      template_engine.OnReplaceTag := TagProcessorAddress;
    Result := template_engine.GetContent;
  except
    on e : Exception do
    begin
      die(e.Message);
    end;
  end;
  if Cache then
    SaveCache(Result);
  if not SubModule then
  begin
    Result := Result + '<!-- '+getDebugInfo('time')+' -->';
    if FHTMLHead.JS.Count>0 then
      Result:=StringReplace(Result,'</head>',FHTMLHead.JS.Text+'</head>',[rfReplaceAll]);
    if FHTMLHead.CSS.Count>0 then
      Result:=StringReplace(Result,'</head>',FHTMLHead.CSS.Text+'</head>',[rfReplaceAll]);
    if FHTMLHead.Meta.Count>0 then
      Result:=StringReplace(Result,'</head>',FHTMLHead.Meta.Text+'</head>',[rfReplaceAll]);
  end;
  if FTrimWhiteSpace then
    Result := DoTrimWhiteSpace(Result,FTrimForce);
  FreeAndNil(template_engine);
end;

function TThemeUtil.RenderFromContent(TagProcessorAddress: TReplaceTagEvent;
  Content: string; TemplateFile: string): string;
var
  template_engine: TFPTemplate;
  html: TStringList;
begin
  html := TStringList.Create;
  //TemplateFile := 'themes/' + ThemeName + '/templates/' + TemplateFile;
  if FileExists(TemplateFile) then
  begin
    html.LoadFromFile(TemplateFile);
    html.Text := StringReplace(html.Text, FStartDelimiter + 'content' +
      FEndDelimiter, Content, [rfReplaceAll]);
  end
  else
    html.Text := Content;

  //-- proccess foreach
  html.Text:= ForeachProcessor( TagProcessorAddress, html.Text);

  template_engine := TFPTemplate.Create;
  template_engine.Template := html.Text;
  template_engine.AllowTagParams := True;
  template_engine.StartDelimiter := FStartDelimiter;
  template_engine.EndDelimiter := FEndDelimiter;
  template_engine.ParamValueSeparator := '=';
  if TagProcessorAddress = nil then
    template_engine.OnReplaceTag := @TagController
  else
    template_engine.OnReplaceTag := TagProcessorAddress;
  Result := template_engine.GetContent;
  FreeAndNil(template_engine);
  FreeAndNil(html);
end;

procedure TThemeUtil.AddJS(const FileName: string);
begin
  FHTMLHead.AddJS(FileName);
end;

procedure TThemeUtil.AddCSS(const FileName: string; const Media: string);
begin
  FHTMLHead.AddCSS(FileName,Media);
end;

procedure TThemeUtil.AddMeta(const Name: string; const Content: string;
  const MetaType: string);
begin
  FHTMLHead.AddMeta(Name,Content,MetaType);
end;

function TThemeUtil.DoTrimWhiteSpace(const Content: string; ForceTrim: boolean
  ): string;
var
  html : TStringList;
  i:integer;
  skip:boolean;
  template_engine : TFPTemplate;
begin
  html := TStringList.Create;
  html.Text:=Content;
  skip:=false;
  for i:=html.Count-1 downto 0 do
  begin
    if Pos('</script',html[i])>0 then skip:=true;
    if Pos('<script',html[i])>0 then skip:=false;
    if (not skip) or ForceTrim then
    begin
      html[i]:=trim(html[i]);
    end;
    if html[i]='' then
      html.Delete(i);
  end;

  // remove comment
  template_engine := TFPTemplate.Create;
  template_engine.Template := html.Text;
  template_engine.AllowTagParams := True;
  template_engine.StartDelimiter := '<!--';
  template_engine.EndDelimiter := '-->';
  template_engine.ParamValueSeparator := '=';
  template_engine.OnReplaceTag := nil;
  Result := template_engine.GetContent;
  FreeAndNil(template_engine);

  Result := Result+'<!-- '+getDebugInfo('time')+'-->';
  FreeAndNil(html);
end;

initialization
  ___TagCallbackMap := TTagCallbackMap.Create;
  ThemeUtil := TThemeUtil.Create;

finalization
  FreeAndNil(ThemeUtil);
  FreeAndNil(___TagCallbackMap);

end.
