//+------------------------------------------------------------------+
//| CLogger.mqh                                                       |
//| Observe et enregistre des faits (pas de decision) :               |
//| - EnregistrerTrade() : positions clôturées                        |
//| - EnregistrerSignalRejete() : signaux valides par IQM/Filtres      |
//|   mais bloques par RiskManagement (avec motif)                    |
//| - CompterPertesConsecutives() / VerifierStaleness() : faits bruts  |
//|   exploites par RiskManagement pour ses propres decisions          |
//+------------------------------------------------------------------+
#property strict

class CLogger
{
private:
   string m_dossier;
   int    m_pertesConsecutives;
   double m_pnlJournalier;
   int    m_jourCourant;
   
   string CheminTrades() const { return m_dossier + "\\trades_log.csv"; }
   string CheminRejets() const { return m_dossier + "\\signaux_rejetes.csv"; }

   void VerifierJour(datetime tCourant)
   {
      MqlDateTime dt;
      TimeToStruct(tCourant, dt);
      if(dt.day_of_year != m_jourCourant)
      {
         m_jourCourant = dt.day_of_year;
         m_pnlJournalier = 0.0;
         m_pertesConsecutives = 0;
      }
   }

public:
   CLogger(string dossier = "ScalpOr") 
   { 
      m_dossier = dossier; 
      m_pertesConsecutives = 0;
      m_pnlJournalier = 0.0;
      
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      m_jourCourant = dt.day_of_year;
   }

   //--- Enregistre une position clôturée. idCalibration identifie la
   //    version de la table de calibration en vigueur au moment du
   //    trade (ex. la date de derniere modification de calibration.csv),
   //    pour pouvoir plus tard distinguer une mauvaise strategie d'une
   //    calibration qui a mal vieilli.
   void EnregistrerTrade(datetime idCalibration, datetime tOuverture, datetime tCloture,
                         double resultatMonetaire, double resultatR,
                         int regime, int bucketRSI, int bucketADX, int bucketATR, int bucketOBV)
   {
      VerifierJour(tCloture);
      m_pnlJournalier += resultatMonetaire;
      if(resultatMonetaire < 0.0) m_pertesConsecutives++;
      else m_pertesConsecutives = 0;

      bool existeDeja = FileIsExist(CheminTrades());
      int handle = FileOpen(CheminTrades(), FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
      if(handle == INVALID_HANDLE) { Print("CLogger : impossible d'ouvrir ", CheminTrades()); return; }

      FileSeek(handle, 0, SEEK_END);
      if(!existeDeja)
         FileWrite(handle, "idCalibration", "tOuverture", "tCloture", "resultatMonetaire", "resultatR",
                            "regime", "bucketRSI", "bucketADX", "bucketATR", "bucketOBV");

      FileWrite(handle, (long)idCalibration, TimeToString(tOuverture, TIME_DATE | TIME_MINUTES),
                TimeToString(tCloture, TIME_DATE | TIME_MINUTES),
                DoubleToString(resultatMonetaire, 2), DoubleToString(resultatR, 2),
                regime, bucketRSI, bucketADX, bucketATR, bucketOBV);

      FileClose(handle);
   }

   //--- Enregistre un signal valide par IQM/Filtres mais rejete par
   //    RiskManagement, avec le motif precis du refus (cf. decision :
   //    AppliquerCircuitBreaker/VerifierExposition retournent bool + motif)
   void EnregistrerSignalRejete(datetime idCalibration, datetime tSignal,
                                 int regime, int bucketRSI, int bucketADX, int bucketATR, int bucketOBV,
                                 double scoreIQM, string motifRejet)
   {
      bool existeDeja = FileIsExist(CheminRejets());
      int handle = FileOpen(CheminRejets(), FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
      if(handle == INVALID_HANDLE) { Print("CLogger : impossible d'ouvrir ", CheminRejets()); return; }

      FileSeek(handle, 0, SEEK_END);
      if(!existeDeja)
         FileWrite(handle, "idCalibration", "tSignal", "regime", "bucketRSI", "bucketADX",
                            "bucketATR", "bucketOBV", "scoreIQM", "motifRejet");

      FileWrite(handle, (long)idCalibration, TimeToString(tSignal, TIME_DATE | TIME_MINUTES),
                regime, bucketRSI, bucketADX, bucketATR, bucketOBV,
                DoubleToString(scoreIQM, 4), motifRejet);

      FileClose(handle);
   }

   //--- Compte les pertes consecutives (en memoire)
   int CompterPertesConsecutives()
   {
      return m_pertesConsecutives;
   }

   //--- Alerte si la table de calibration n'a pas ete rechargee depuis
   //    trop longtemps (rechargement silencieux jamais declenche, cf.
   //    le risque identifie sur la fenetre horaire OnTimer)
   bool VerifierStaleness(datetime derniereRecharge, int seuilHeures = 24)
   {
      double heuresEcoulees = (double)(TimeCurrent() - derniereRecharge) / 3600.0;
      if(heuresEcoulees > seuilHeures)
      {
         Print("ALERTE CLogger : calibration non rechargee depuis ", DoubleToString(heuresEcoulees, 1), " heures");
         return true;
      }
      return false;
   }

   //--- Resultat net cumule (gains ET pertes) depuis un instant donne --
   //    Maintenant gere en memoire pour eviter la lecture de fichier.
   double ObtenirResultatNetCumule(datetime depuis)
   {
      VerifierJour(TimeCurrent());
      return m_pnlJournalier;
   }
};
