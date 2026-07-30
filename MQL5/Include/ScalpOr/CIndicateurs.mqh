//+------------------------------------------------------------------+
//| CIndicateurs.mqh                                                   |
//| Centralise les handles d'indicateurs (RSI/ADX/ATR/OBV M1,          |
//| SuperTrend M15) partages par CIQM, CFiltres et CExecution -- evite |
//| de creer les memes handles a trois endroits differents.            |
//|                                                                    |
//| CORRECTION : le placeholder EMA50 M15 (iMA) est remplace par le    |
//| vrai SuperTrend M15 (indicateur personnalise SuperTrend.mq5,       |
//| compile dans MQL5/Indicators/ScalpOr/). CEncodageEtat::Regime()    |
//| n'a pas besoin de changer : la ligne SuperTrend se comporte comme  |
//| l'EMA (sous le prix en tendance haussiere, au-dessus en baissiere),|
//| donc la comparaison close > ligne / close < ligne reste valide.    |
//|                                                                    |
//| CORRECTION (bug MT5 tester) : l'appel iCustom("ScalpOr\\SuperTrend")|
//| echouait systematiquement dans le Testeur de strategie (erreurs    |
//| 557/4802, "program file ... read error") -- bug connu de MT5 ou    |
//| l'agent du testeur ne resynchronise pas fiablement les indicateurs |
//| personnalises sur disque. Solution : SuperTrend.ex5 est embarque   |
//| comme RESSOURCE directement dans le programme qui l'utilise (EA ou |
//| script), via #resource, et charge depuis cette ressource (prefixe  |
//| "::") plutot que depuis le disque. Ca supprime toute dependance a  |
//| la synchronisation de fichiers du testeur.                         |
//| IMPORTANT : SuperTrend.ex5 doit deja exister et etre a jour dans   |
//| MQL5/Indicators/ScalpOr/ AU MOMENT de la compilation de ce fichier  |
//| (et de tout fichier qui l'inclut) -- la ressource est figee au     |
//| moment de la compilation, pas relue dynamiquement ensuite.         |
//+------------------------------------------------------------------+
#property strict
#resource "\\Indicators\\ScalpOr\\SuperTrend.ex5"

class CIndicateurs
{
private:
   string m_symbole;
   int    m_hRSI_M1;
   int    m_hADX_M1;
   int    m_hATR_M1;
   int    m_hOBV_M1;
   int    m_hSuperTrend_M15;
   int    m_periodeATR_SuperTrend;
   double m_multiplicateur_SuperTrend;

public:
   CIndicateurs(string symbole = "GOLD", int periodeATR_SuperTrend = 10, double multiplicateur_SuperTrend = 3.0)
   {
      m_symbole = symbole;
      m_periodeATR_SuperTrend = periodeATR_SuperTrend;
      m_multiplicateur_SuperTrend = multiplicateur_SuperTrend;
      m_hRSI_M1 = INVALID_HANDLE;
      m_hADX_M1 = INVALID_HANDLE;
      m_hATR_M1 = INVALID_HANDLE;
      m_hOBV_M1 = INVALID_HANDLE;
      m_hSuperTrend_M15 = INVALID_HANDLE;
   }

   bool Initialiser()
   {
      m_hRSI_M1 = iRSI(m_symbole, PERIOD_M1, 14, PRICE_CLOSE);
      m_hADX_M1 = iADX(m_symbole, PERIOD_M1, 14);
      m_hATR_M1 = iATR(m_symbole, PERIOD_M1, 14);
      m_hOBV_M1 = iOBV(m_symbole, PERIOD_M1, VOLUME_TICK);
      m_hSuperTrend_M15 = iCustom(m_symbole, PERIOD_M15, "::Indicators\\ScalpOr\\SuperTrend.ex5",
                                   m_periodeATR_SuperTrend, m_multiplicateur_SuperTrend);

      if(m_hRSI_M1 == INVALID_HANDLE || m_hADX_M1 == INVALID_HANDLE || m_hATR_M1 == INVALID_HANDLE ||
         m_hOBV_M1 == INVALID_HANDLE || m_hSuperTrend_M15 == INVALID_HANDLE)
      {
         Print("CIndicateurs : echec de creation d'un handle d'indicateur");
         return false;
      }
      return true;
   }

   void Liberer()
   {
      if(m_hRSI_M1 != INVALID_HANDLE) IndicatorRelease(m_hRSI_M1);
      if(m_hADX_M1 != INVALID_HANDLE) IndicatorRelease(m_hADX_M1);
      if(m_hATR_M1 != INVALID_HANDLE) IndicatorRelease(m_hATR_M1);
      if(m_hOBV_M1 != INVALID_HANDLE) IndicatorRelease(m_hOBV_M1);
      if(m_hSuperTrend_M15 != INVALID_HANDLE) IndicatorRelease(m_hSuperTrend_M15);
   }

private:
   double Lire(int handle, int shift)
   {
      double buffer[];
      ArraySetAsSeries(buffer, true);
      if(CopyBuffer(handle, 0, shift, 1, buffer) <= 0) return 0.0;
      return buffer[0];
   }

public:
   double RSI(int shift)  { return Lire(m_hRSI_M1, shift); }
   double ADX(int shift)  { return Lire(m_hADX_M1, shift); } // buffer principal
   double ATR(int shift)  { return Lire(m_hATR_M1, shift); }
   double OBV(int shift)  { return Lire(m_hOBV_M1, shift); }

   //--- Ligne SuperTrend M15 (remplace l'ancien MA_M15/EMA50 placeholder).
   //    Renomme pour refleter la nouvelle source ; meme usage cote appelant :
   //    close > SuperTrend_M15() = haussier, close < SuperTrend_M15() = baissier.
   double SuperTrend_M15(int shift) { return Lire(m_hSuperTrend_M15, shift); }
};
