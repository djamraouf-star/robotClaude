//+------------------------------------------------------------------+
//| CFiltres.mqh                                                      |
//| Conditions booleennes independantes, calibrees par bucket isole   |
//| (pas par etat complet comme IQM) : un bucket est juge favorable    |
//| A LA DIRECTION DONNEE si sa probabilite marginale historique       |
//| depasse la probabilite de base globale (signal haussier) ou lui   |
//| est inferieure (signal baissier). Bucket jamais rencontre -> false |
//| (meme prudence que l'hypothese retenue pour IQM sur les etats     |
//| inconnus).                                                        |
//|                                                                    |
//| CORRECTION (investigation "0 short en marche baissier") :          |
//| EstFavorable() et les 4 methodes publiques prenaient un jugement   |
//| unidirectionnel (toujours "favorable a la hausse"), ce qui         |
//| bloquait systematiquement tout signal IQM baissier (-1) au niveau  |
//| du garde-fou signalFiltres dans CExecution::ArbitrerSignaux(),     |
//| meme quand IQM detectait correctement un etat baissier calibre.    |
//|                                                                    |
//| CORRECTION (SuperTrend) : TendanceOK() utilise desormais le vrai   |
//| SuperTrend M15 (CIndicateurs.SuperTrend_M15) au lieu du placeholder |
//| EMA50. CEncodageEtat::Regime() n'a pas change.                     |
//|                                                                    |
//| Utilise CIndicateurs (lecture partagee) et CEncodageEtat (logique  |
//| de bucket partagee) -- plus aucune duplication avec CIQM ou        |
//| ScalpOr_MoteurProbabiliste.mq5.                                     |
//+------------------------------------------------------------------+
#property strict
#include <ScalpOr/CFichierCalibration.mqh>
#include <ScalpOr/CIndicateurs.mqh>
#include <ScalpOr/CEncodageEtat.mqh>

class CFiltres
{
private:
   CFichierCalibration *m_calibration; // reference partagee avec IQM
   CIndicateurs        *m_indicateurs; // reference partagee (RSI/ADX/ATR/OBV/SuperTrend_M15)
   string m_symbole;

   //--- Un bucket est juge favorable A LA DIRECTION donnee :
   //    - direction > 0 (signal haussier) : probabilite marginale au-dessus de la base
   //    - direction < 0 (signal baissier) : probabilite marginale en-dessous de la base
   //    Bucket inconnu -> non favorable (prudence), quelle que soit la direction.
   bool EstFavorable(double probaMarginale, int direction)
   {
      if(probaMarginale < 0.0) return false; // bucket jamais rencontre a la calibration
      if(direction > 0) return probaMarginale > m_calibration.ObtenirProbabiliteBase();
      return probaMarginale < m_calibration.ObtenirProbabiliteBase();
   }

public:
   CFiltres(CFichierCalibration *calibration, CIndicateurs *indicateurs, string symbole = "GOLD")
   {
      m_calibration = calibration;
      m_indicateurs = indicateurs;
      m_symbole = symbole;
   }

   //--- Tendance (regime M15, via le vrai SuperTrend)
   bool TendanceOK(int direction)
   {
      double closeM15      = iClose(m_symbole, PERIOD_M15, 1);
      double superTrendM15 = m_indicateurs.SuperTrend_M15(1);
      int regime = CEncodageEtat::Regime(closeM15, superTrendM15);

      return EstFavorable(m_calibration.ObtenirProbabiliteMarginaleRegime(regime), direction);
   }

   //--- Momentum (RSI M1)
   bool MomentumOK(int direction)
   {
      int bucket = CEncodageEtat::BucketRSI(m_indicateurs.RSI(1));
      return EstFavorable(m_calibration.ObtenirProbabiliteMarginale(TYPE_RSI, bucket), direction);
   }

   //--- Volume (OBV M1, pente sur 10 barres)
   bool VolumeOK(int direction)
   {
      int bucket = CEncodageEtat::BucketOBV(m_indicateurs.OBV(1), m_indicateurs.OBV(11));
      return EstFavorable(m_calibration.ObtenirProbabiliteMarginale(TYPE_OBV, bucket), direction);
   }

   //--- Volatilite (ATR M1, terciles issus de la calibration)
   bool VolatiliteOK(int direction)
   {
      double terciles[];
      m_calibration.ObtenirTercilesATR(terciles);
      int bucket = CEncodageEtat::BucketATR(m_indicateurs.ATR(1), terciles[0], terciles[1]);

      return EstFavorable(m_calibration.ObtenirProbabiliteMarginale(TYPE_ATR, bucket), direction);
   }
};
