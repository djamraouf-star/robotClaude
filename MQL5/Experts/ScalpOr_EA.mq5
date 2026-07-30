//+------------------------------------------------------------------+
//| ScalpOr_EA.mq5                                                     |
//| EA principal : ne contient QUE l'assemblage des classes et les     |
//| handlers MQL5 (OnInit/OnTick/OnTimer/OnDeinit). Toute la logique    |
//| metier vit dans Include/ScalpOr/.                                  |
//|                                                                    |
//| Rythme des handlers (cf. decision sur la separation classes/       |
//| machines/indicateurs) :                                            |
//| - OnTick()  : Execution.Coordonner() -- haute frequence            |
//| - OnTimer() : verification + bascule de la calibration, dans une   |
//|               fenetre horaire calme uniquement                     |
//+------------------------------------------------------------------+
#property strict
#include <ScalpOr/CFichierCalibration.mqh>
#include <ScalpOr/CIndicateurs.mqh>
#include <ScalpOr/CIQM.mqh>
#include <ScalpOr/CFiltres.mqh>
#include <ScalpOr/CLogger.mqh>
#include <ScalpOr/CRiskManagement.mqh>
#include <ScalpOr/CModuleOrdres.mqh>
#include <ScalpOr/CDebugger.mqh>
#include <ScalpOr/CExecution.mqh>

//--- Parametres d'entree
input string SymboleCible           = "GOLD";
input double MultipleATR_SLTP       = 1.0;
input double PasTrailingATR          = 0.5; // le SL ne bouge que si le prix gagne au moins ce multiple d'ATR
input double MargeSignalIQM          = 0.05; // marge mini au-dessus de la proba de base (+5 pts)
input double MargeMinimaleIQM        = 0.05; // marge de proba au-dessus du hasard pour qu'un état génère un signal
input double ExpositionMaxPourcent  = 3.0;
input int    NbPositionsMax         = 1;
input int    SeuilPertesConsecutives = 5;
input double RisqueParTradePourcent = 1.0;
input double DrawdownJournalierMax  = 5.0;
input int    HeureDebutFenetreCalme = 22; // heure serveur, cf. decision rollover
input int    HeureFinFenetreCalme   = 23;
input bool   ActiverDebugger        = true; // activation des traces de debug

//--- Instances (creees dans OnInit, liberees dans OnDeinit)
CFichierCalibration *g_calibration;
CIndicateurs        *g_indicateurs;
CIQM                *g_iqm;
CFiltres            *g_filtres;
CLogger             *g_logger;
CRiskManagement     *g_risk;
CModuleOrdres       *g_ordres;
CDebugger           *g_debugger;
CExecution          *g_execution;

//+------------------------------------------------------------------+
int OnInit()
{
   g_calibration = new CFichierCalibration("ScalpOr");
   if(!g_calibration.Charger())
   {
      Print("ScalpOr_EA : echec du chargement initial de la calibration -- ",
            "avez-vous execute ScalpOr_MoteurProbabiliste.mq5 au prealable ?");
      return INIT_FAILED;
   }

   g_indicateurs = new CIndicateurs(SymboleCible);
   if(!g_indicateurs.Initialiser())
   {
      Print("ScalpOr_EA : echec d'initialisation de CIndicateurs");
      return INIT_FAILED;
   }

   g_iqm = new CIQM(g_calibration, g_indicateurs, SymboleCible);
   g_filtres = new CFiltres(g_calibration, g_indicateurs, SymboleCible);

   g_logger = new CLogger("ScalpOr");
   g_risk = new CRiskManagement(ExpositionMaxPourcent, NbPositionsMax, SeuilPertesConsecutives,
                                 RisqueParTradePourcent, DrawdownJournalierMax, SymboleCible);
   g_ordres = new CModuleOrdres(SymboleCible, PasTrailingATR);

   ENUM_DEBUG_LEVEL dbgLevel = ActiverDebugger ? DEBUG_LEVEL_TRACE : DEBUG_LEVEL_NONE;
   g_debugger = new CDebugger("ScalpOr", "debug_trace.log", dbgLevel);

   g_execution = new CExecution(g_iqm, g_filtres, g_calibration, g_logger, g_risk, g_ordres,
                                 g_indicateurs, g_debugger, SymboleCible, MultipleATR_SLTP, MargeSignalIQM);

   //--- Verification de la calibration toutes les heures (cf. decision :
   //    le timer peut tourner souvent, seule la BASCULE est restreinte
   //    a la fenetre horaire calme, geree dans OnTimer)
   EventSetTimer(3600);

   Print("ScalpOr_EA : initialisation terminee, ", g_calibration.NombreEtats(), " etats charges");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   if(g_indicateurs != NULL) g_indicateurs.Liberer();

   delete g_execution;
   delete g_debugger;
   delete g_ordres;
   delete g_risk;
   delete g_logger;
   delete g_filtres;
   delete g_iqm;
   delete g_indicateurs;
   delete g_calibration;
}

//+------------------------------------------------------------------+
void OnTick()
{
   g_execution.Coordonner();
}

//+------------------------------------------------------------------+
//| Verifie et, si besoin, bascule la calibration -- uniquement       |
//| pendant la fenetre horaire calme (cf. decision : jamais en pleine  |
//| session active, pour ne pas melanger deux regimes de calibration   |
//| a l'interieur d'une meme position en cours).                       |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(!g_calibration.VerifierDate()) return; // rien de nouveau, on attend le prochain passage

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   bool dansLaFenetre = (dt.hour >= HeureDebutFenetreCalme && dt.hour < HeureFinFenetreCalme);

   if(!dansLaFenetre)
   {
      Print("ScalpOr_EA : nouvelle calibration detectee, bascule differee (hors fenetre horaire calme)");
      return;
   }

   if(g_ordres.EtatActuel() != ETAT_IDLE)
   {
      Print("ScalpOr_EA : nouvelle calibration detectee mais position en cours, bascule differee");
      return;
   }

   if(g_calibration.Charger())
      Print("ScalpOr_EA : calibration rechargee (", g_calibration.NombreEtats(), " etats)");
   else
      Print("ScalpOr_EA : ERREUR lors du rechargement de la calibration");
}
