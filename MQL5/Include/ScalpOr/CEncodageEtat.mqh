//+------------------------------------------------------------------+
//| CEncodageEtat.mqh                                                  |
//| Logique de bucket UNIQUE, partagee entre ScalpOr_MoteurProbabiliste|
//| .mq5 (calibration hors ligne), CIQM et CFiltres (temps reel).      |
//|                                                                    |
//| Avant cette factorisation, les seuils (RSI<40, ADX>=25, etc.)      |
//| etaient ecrits a trois endroits differents -- tout changement de  |
//| seuil devait etre reporte manuellement partout, avec le risque      |
//| exact que cette architecture cherchait a eliminer (parametres      |
//| caches, incoherents entre calibration et temps reel).              |
//+------------------------------------------------------------------+
#property strict

class CEncodageEtat
{
public:
   //--- RSI : 0 bas (<40), 1 neutre (40-60), 2 haut (>60)
   static int BucketRSI(double rsi)
   {
      if(rsi < 40.0) return 0;
      if(rsi > 60.0) return 2;
      return 1;
   }

   //--- ADX : 0 faible (<25), 1 fort (>=25)
   static int BucketADX(double adx)
   {
      return (adx >= 25.0) ? 1 : 0;
   }

   //--- ATR : 0/1/2 selon les terciles fournis (calcules par MoteurProbabiliste,
   //    lus depuis calibration en temps reel -- jamais recalcules localement)
   static int BucketATR(double atr, double tercileBas, double tercileHaut)
   {
      if(atr < tercileBas) return 0;
      if(atr > tercileHaut) return 2;
      return 1;
   }

   //--- OBV : 0 baissier, 1 haussier (pente sur l'ecart fourni, ex. 10 barres)
   static int BucketOBV(double obvActuel, double obvPasse)
   {
      return (obvActuel >= obvPasse) ? 1 : 0;
   }

   //--- Regime (M15) : -1 baissier, 0 neutre, 1 haussier
   //    TODO : placeholder EMA50 -- a remplacer par le vrai SuperTrend M15,
   //    a ce SEUL endroit desormais (au lieu de trois).
   static int Regime(double closeM15, double emaM15)
   {
      if(closeM15 > emaM15) return 1;
      if(closeM15 < emaM15) return -1;
      return 0;
   }
};
