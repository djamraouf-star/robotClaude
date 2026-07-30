//+------------------------------------------------------------------+
//| CIQM.mqh                                                          |
//| Score de qualite de marche en temps reel, base sur l'etat actuel   |
//| (RSI/ADX/ATR/OBV M1 + regime M15) et la table de calibration       |
//| chargee via CFichierCalibration.                                   |
//|                                                                    |
//| Utilise CIndicateurs (lecture partagee) et CEncodageEtat (logique  |
//| de bucket partagee) -- plus aucune duplication avec CFiltres ou    |
//| ScalpOr_MoteurProbabiliste.mq5.                                    |
//|                                                                    |
//| CORRECTION : le regime utilise desormais le vrai SuperTrend M15    |
//| (CIndicateurs.SuperTrend_M15) au lieu du placeholder EMA50.        |
//| CEncodageEtat::Regime() n'a pas change -- seule la source de la    |
//| deuxieme valeur comparee au close a change.                        |
//|                                                                    |
//| Hypothese assumee (a confirmer) : un etat inconnu de la table de   |
//| calibration (jamais rencontre, ou sous-echantillonne) est traite   |
//| comme NEUTRE (score = 0) -> IQM ne validera pas un signal sur un   |
//| etat qu'il n'a jamais mesure, plutot que de deviner.               |
//+------------------------------------------------------------------+
#property strict
#include <ScalpOr/CFichierCalibration.mqh>
#include <ScalpOr/CIndicateurs.mqh>
#include <ScalpOr/CEncodageEtat.mqh>

class CIQM
{
private:
   CFichierCalibration *m_calibration; // reference partagee, pas de copie
   CIndicateurs        *m_indicateurs; // reference partagee (RSI/ADX/ATR/OBV/SuperTrend_M15)
   string m_symbole;
   double m_margeMinimale; // marge de proba au-dessus de la base pour qu'un etat compte comme signal

public:
   CIQM(CFichierCalibration *calibration, CIndicateurs *indicateurs,
        string symbole = "GOLD", double margeMinimale = 0.05)
   {
      m_calibration = calibration;
      m_indicateurs = indicateurs;
      m_symbole = symbole;
      m_margeMinimale = margeMinimale;
   }

   //--- Encode l'etat de marche courant via CEncodageEtat (source unique
   //    des seuils, partagee avec CFiltres et le script de calibration)
   void ObtenirEtatMarche(int &regime, int &bucketRSI, int &bucketADX, int &bucketATR, int &bucketOBV)
   {
      double closeM15      = iClose(m_symbole, PERIOD_M15, 1); // derniere bougie M15 CLOTUREE
      double superTrendM15 = m_indicateurs.SuperTrend_M15(1);
      regime = CEncodageEtat::Regime(closeM15, superTrendM15);

      // shift 1 = derniere bougie M1 cloturee, coherent avec la calibration
      bucketRSI = CEncodageEtat::BucketRSI(m_indicateurs.RSI(1));
      bucketADX = CEncodageEtat::BucketADX(m_indicateurs.ADX(1));

      double terciles[];
      m_calibration.ObtenirTercilesATR(terciles);
      bucketATR = CEncodageEtat::BucketATR(m_indicateurs.ATR(1), terciles[0], terciles[1]);

      bucketOBV = CEncodageEtat::BucketOBV(m_indicateurs.OBV(1), m_indicateurs.OBV(11));
   }

   //--- Score de qualite de marche courant, entre -1 (tres defavorable
   //    a l'hypothese haussiere) et 1 (tres favorable). 0 = neutre,
   //    etat inconnu, OU etat dont la probabilite ne depasse pas la
   //    probabilite de base d'au moins m_margeMinimale (le seuil de
   //    signal derive de la calibration, pas d'un chiffre fixe arbitraire
   //    sur le score brut).
   double CalculerScore()
   {
      int regime, bRSI, bADX, bATR, bOBV;
      ObtenirEtatMarche(regime, bRSI, bADX, bATR, bOBV);

      double probabilite = m_calibration.ObtenirProbabilite(regime, bRSI, bADX, bATR, bOBV);

      if(probabilite < 0.0) return 0.0; // etat inconnu -> neutre, pas de trade

      //--- Seuil de signal : l'etat doit etre meilleur (ou pire, pour un
      //    signal vendeur) que le hasard d'une marge minimale interpretable.
      //    Un etat trop proche de la proba de base ne genere aucun signal.
      double base  = m_calibration.ObtenirProbabiliteBase();
      double ecart = probabilite - base;
      if(MathAbs(ecart) < m_margeMinimale) return 0.0;

      double poidsMoyen = (m_calibration.ObtenirPoids(TYPE_RSI) + m_calibration.ObtenirPoids(TYPE_ADX) +
                           m_calibration.ObtenirPoids(TYPE_ATR) + m_calibration.ObtenirPoids(TYPE_OBV)) / 4.0;

      double score = (probabilite - 0.5) * 2.0; // ramene [0,1] vers [-1,1]
      return score * (poidsMoyen * 4.0); // repondere par la confiance globale de l'etat
   }

   //--- Un signal est valide si l'etat courant est mesurablement meilleur
   //    que le hasard : sa probabilite doit depasser la probabilite de base
   //    globale d'au moins margeMin (ex. 0.05 = +5 points au-dessus du
   //    hasard). Seuil INTERPRETABLE, contrairement a un seuil sur le score
   //    brut dont la plage depend des poids calibres inconnus a l'avance.
   //    Retourne 0 si pas de signal, 1 si signal haussier, -1 si baissier.
   int SignalDirectionnel(double margeMin)
   {
      int regime, bRSI, bADX, bATR, bOBV;
      ObtenirEtatMarche(regime, bRSI, bADX, bATR, bOBV);

      double probabilite = m_calibration.ObtenirProbabilite(regime, bRSI, bADX, bATR, bOBV);
      if(probabilite < 0.0) return 0; // etat inconnu -> pas de signal

      double base = m_calibration.ObtenirProbabiliteBase();

      // Ecart au-dessus de la base -> favorable (haussier) ;
      // ecart symetrique en-dessous -> defavorable (baissier).
      if(probabilite >= base + margeMin) return 1;
      if(probabilite <= base - margeMin) return -1;
      return 0; // dans la zone neutre autour de la base -> on ne trade pas
   }
};
