unit Main;

interface

uses
  Winapi.Windows, Winapi.Messages, Winapi.WinSvc,
  System.SysUtils, System.Classes, Vcl.Graphics, Vcl.Controls, Vcl.SvcMgr, Vcl.Dialogs,
  System.IOUtils, System.JSON;

type
  TeServicesGuard = class(TService)
    procedure ServiceStart(Sender: TService; var Started: Boolean);
    procedure ServiceStop(Sender: TService; var Stopped: Boolean);
    procedure ServiceExecute(Sender: TService);

  private
    { Private declarations }
	  sciezkaPlikLog: string; //�ciezka do pliku log
    konfiguracja: TJSONObject;

    procedure wczytajKonfiguracje();
    procedure loguj(wiadomosc: string);
    procedure uruchomUslugi(listaUslug: TJSONArray; konsolaUslug: SC_HANDLE);
    function konwertujSekundyNaIteracje(sekundy: Integer; interwal: Integer): Integer;

  public
    function GetServiceController: TServiceController; override;
    { Public declarations }
  end;

var
  eServicesGuard: TeServicesGuard;

implementation

{$R *.dfm}

procedure ServiceController(CtrlCode: DWord); stdcall;
begin
  eServicesGuard.Controller(CtrlCode);
end;

function TeServicesGuard.GetServiceController: TServiceController;
begin
  Result := ServiceController;
end;

procedure TeServicesGuard.loguj(wiadomosc: string);
var
  tekst: string;
begin
  tekst := DateTimeToStr(Now()) + ' - ' + wiadomosc + sLineBreak;
  TFile.AppendAllText(sciezkaPlikLog, tekst, TEncoding.UTF8);
end;

function TeServicesGuard.konwertujSekundyNaIteracje(sekundy: Integer; interwal: Integer): Integer;
begin
  Result := (sekundy * Round(1000 / interwal));
end;

procedure TeServicesGuard.ServiceExecute(Sender: TService);
var
  scHandler: SC_HANDLE;
  interwalUslug: Integer; //ile sekund up�ynie do nastepnego sprawdzenia us�ug
  interwalKonfig: Integer; //ile sekund up�ynie do nastepnego wczytania konfiguracji
  interwal: integer; //milisekund ile b�dzie us�uga u�piona
begin
  {Wczytaj konsole us�ug}
  scHandler := OpenSCManager(nil, nil, SC_MANAGER_ALL_ACCESS);

  if scHandler = 0 then
  begin
    loguj('Nie uda�o si� za�adowa� konsoli us�ug.');
    eServicesGuard.DoStop();
    Exit();
  end;

  interwalUslug := 1;
  interwalKonfig := 0;
  interwal := 500;

  while eServicesGuard.Terminated = false do
  begin
    {sprawd� czy czas ju� na test statusu us�ug}
    if (interwalUslug < 1) then
    begin
      if ( ((konfiguracja.GetValue('informujSprawdzanieUslug') as TJSONBool).AsBoolean) = True) then
        loguj('Sprawdzam stan us�ug.');
      uruchomUslugi(konfiguracja.GetValue('uruchomUslugi') as TJSONArray, scHandler);
      interwalUslug := konwertujSekundyNaIteracje(StrToInt(konfiguracja.GetValue('sprawdzUslugiCoXSekund').Value()), interwal);
    end;

    {sprawd� czy czas ju� na wczytanie konfiguracji}
    if (interwalKonfig < 1) then
    begin
      wczytajKonfiguracje();
      interwalKonfig := konwertujSekundyNaIteracje(StrToInt(konfiguracja.GetValue('wczytajKonfiguracjeCoXSekund').Value()), interwal);
    end;

    Dec(interwalUslug, 1);
    Dec(interwalKonfig, 1);

    ServiceThread.ProcessRequests(false);
    Sleep(interwal);
  end;

  CloseHandle(scHandler);
end;

procedure TeServicesGuard.uruchomUslugi(listaUslug: TJSONArray; konsolaUslug: NativeUInt);
var
  licznik: Integer;
  uHandler: SC_HANDLE;
  uStatus: SERVICE_STATUS;
  czyOk: Boolean;
  sztucznyZnak: PWideChar;
  nazwaUslugi: PWideChar;

begin
  sztucznyZnak := nil;

  for licznik := 0 to listaUslug.Count - 1 do
  begin
    nazwaUslugi := PWideChar (listaUslug.Items[licznik].Value());
    {za�aduj us�ug�}
    uHandler := OpenService(konsolaUslug, nazwaUslugi, SC_MANAGER_ALL_ACCESS);
    if uHandler = 0 then
    begin
      loguj('Nie mo�na uzyska� dost�pu do us�ugi ' + nazwaUslugi + '.');
      Continue;
    end;

    {pobierz informacje o us�udze}
    czyOk := QueryServiceStatus(uHandler, uStatus);
    if czyOk = false then
    begin
      loguj('Nie mo�na uzyska� informacji na temat us�ugi ' + nazwaUslugi + '.');
      CloseServiceHandle(uHandler);
      Continue;
    end;

    {je�eli us�uga jest zatrzymana - uruchom j�}
    if uStatus.dwCurrentState = SERVICE_STOPPED then
    begin
      czyOk := StartService(uHandler, 0, sztucznyZnak);
      if czyOk = false then
      begin
        loguj('Nie mo�na uruchomi� us�ugi ' + nazwaUslugi + '.');
        CloseServiceHandle(uHandler);
        Continue;
      end;

      loguj('Uruchamiam us�ug� ' + nazwaUslugi);

      repeat
        czyOk := QueryServiceStatus(uHandler, uStatus);
        if czyOk = false then
        begin
          loguj('Nie mo�na uzyska� informacji na temat us�ugi ' + nazwaUslugi + '.');
          CloseServiceHandle(uHandler);
          Break;
        end;

        if(uStatus.dwWaitHint = 0) then Sleep(1000);
        if((uStatus.dwWaitHint > 0) and (uStatus.dwWaitHint < 5000)) then Sleep(uStatus.dwWaitHint);
        if(uStatus.dwWaitHint >= 5000) then Sleep( Round(uStatus.dwWaitHint / 2));

      until uStatus.dwCurrentState <> SERVICE_START_PENDING;

      if(uStatus.dwCurrentState = SERVICE_RUNNING) then loguj('Poprawnie uruchomiono us�ug� ' + nazwaUslugi)
      else loguj('Usluga ' + nazwaUslugi + ' nie zosta�a poprawnie uruchomiona. Kod b��du ' + IntToStr(uStatus.dwWin32ExitCode));
    end;

    CloseServiceHandle(uHandler);
  end;
end;

procedure TeServicesGuard.ServiceStart(Sender: TService; var Started: Boolean);
begin
  konfiguracja := nil;
  sciezkaPlikLog := ExtractFilePath(ParamStr(0)) + 'eServiceGuard.log';
  loguj('Us�uga zosta�a uruchomiona');
end;

procedure TeServicesGuard.ServiceStop(Sender: TService; var Stopped: Boolean);
begin
  loguj('Za��dano zatrzymanie us�ugi');
  if Assigned(konfiguracja) then konfiguracja.Free();
end;

procedure TeServicesGuard.wczytajKonfiguracje();
var
  sciezka: string;
begin
  loguj('Wczytuj� plik konfiguracji');
  sciezka := ExtractFilePath(ParamStr(0)) + 'eServiceGuard.json';
  if Assigned(konfiguracja) then konfiguracja.Free();
  if TFile.Exists(sciezka) = false then
  begin
    loguj('Brak pliku konfiguracyjnego: ' + sciezka);
    eServicesGuard.DoStop();
    Exit();
  end;

  konfiguracja := TJSONObject.ParseJSONValue(TFile.ReadAllBytes(sciezka), 0, true) as TJSONObject;

  if(konfiguracja = nil) then
  begin
    loguj('Parsowanie pliku konfiguracyjnego nie powiod�o si�.');
    eServicesGuard.DoStop();
    Exit();
  end;
end;

end.

