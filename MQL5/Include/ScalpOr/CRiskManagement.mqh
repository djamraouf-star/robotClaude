//+------------------------------------------------------------------+
//| CRiskManagement.mqh                                              |
//| Regles de capital, independantes de la qualite du signal du       |
//| moment (sauf CalculerTailleLot, qui pondere a l'interieur d'un    |
//| plafond toujours fixe par les regles de risque).                  |
//|                                                                    |
//| Reste isole des autres modules : ne lit ni IQM, ni Logger          |
//| directement. Execution transmet les valeurs necessaires (score    |
//| IQM, pertes consecutives) en parametres.                           |
//+------------------------------------------------------------------+
#property strict

//--- Retour bool + motif (cf. decision : jamais un simple booleen brut,
//    pour permettre l'analyse future des signaux rejetes via CLogger)
struct SResultatVerification
{
   bool   autorise;
   string motif; // vide si autorise, sinon code du motif de refus
};

class CRiskManagement
{
private:
   double m_expositionMaxPourcent;     // % du capital, exposition totale max
   int    m_nbPositionsMax;            // nombre de positions simultanees max
   int    m_seuilPertesConsecutives;   // circuit breaker
   double m_risqueParTradePourcent;    // % du capital risque par trade (base, avant ponderation IQM)
   double m_drawdownJournalierMaxPourcent;
   string m_symbole;

public:
   CRiskManagement(double expositionMaxPourcent = 3.0,
                   int    nbPositionsMax = 1,
                   int    seuilPertesConsecutives = 5,
                   double risqueParTradePourcent = 1.0,
                   double drawdownJournalierMaxPourcent = 5.0,
                   string symbole = "GOLD")
   {
      m_expositionMaxPourcent          = expositionMaxPourcent;
      m_nbPositionsMax                 = nbPositionsMax;
      m_seuilPertesConsecutives        = seuilPertesConsecutives;
      m_risqueParTradePourcent         = risqueParTradePourcent;
      m_drawdownJournalierMaxPourcent  = drawdownJournalierMaxPourcent;
      m_symbole                        = symbole;
   }

   //--- Exposition totale : nombre de positions ouvertes + % de capital deja engage.
   //    Parametres fournis par Execution (pas de lecture directe d'un autre module).
   SResultatVerification VerifierExposition(int nbPositionsOuvertes, double expositionActuellePourcent)
   {
      SResultatVerification r;

      if(nbPositionsOuvertes >= m_nbPositionsMax)
      {
         r.autorise = false;
         r.motif = "EXPOSITION_NB_POSITIONS_MAX";
         return r;
      }

      if(expositionActuellePourcent >= m_expositionMaxPourcent)
      {
         r.autorise = false;
         r.motif = "EXPOSITION_POURCENT_MAX";
         return r;
      }

      r.autorise = true;
      r.motif = "";
      return r;
   }

   //--- Circuit breaker sur pertes consecutives. pertesConsecutives est
   //    fourni par Execution, lui-meme lu depuis CLogger.CompterPertesConsecutives()
   SResultatVerification AppliquerCircuitBreaker(int pertesConsecutives)
   {
      SResultatVerification r;

      if(pertesConsecutives >= m_seuilPertesConsecutives)
      {
         r.autorise = false;
         r.motif = "CIRCUIT_BREAKER_PERTES_CONSECUTIVES";
         return r;
      }

      r.autorise = true;
      r.motif = "";
      return r;
   }

   //--- Drawdown journalier : seuil fixe, applique a l'accumulation
   //    monetaire nette reelle de la journee (fournie par Execution, calculee
   //    depuis Logger) -- ce signal est independant du circuit breaker :
   //    celui-ci compte des pertes CONSECUTIVES, celui-la mesure une perte
   //    NETTE cumulee, qui capture aussi un motif "grosse perte, petit gain,
   //    grosse perte" que le circuit breaker ne verrait jamais (chaque gain,
   //    meme minime, remet son compteur a zero).
   SResultatVerification VerifierDrawdownJournalier(double drawdownActuelPourcent)
   {
      SResultatVerification r;

      if(drawdownActuelPourcent >= m_drawdownJournalierMaxPourcent)
      {
         r.autorise = false;
         r.motif = "DRAWDOWN_JOURNALIER_MAX";
         return r;
      }

      r.autorise = true;
      r.motif = "";
      return r;
   }

   //--- Taille de lot : le plafond de risque (risqueParTradePourcent) est
   //    TOUJOURS respecte ; le score IQM ne fait que moduler a l'interieur
   //    de ce plafond (facteur entre 0.5 et 1.0), jamais au-dela.
   //    slDistancePrix = distance du SL en PRIX (ex. atr * multiple), pas
   //    en "points" -- la conversion en risque monetaire par lot se fait
   //    via OrderCalcProfit pour garantir la bonne conversion de devise.
   //    NB : formule de ponderation a valider empiriquement, cf. remarque
   //    equivalente sur CIQM.CalculerScore().
   double CalculerTailleLot(double scoreIQM, double capitalDisponible, double slDistancePrix)
   {
      if(slDistancePrix <= 0.0 || capitalDisponible <= 0.0) return 0.0;

      double risqueMonetaireBase = capitalDisponible * (m_risqueParTradePourcent / 100.0);

      // scoreIQM dans [-1, 1] -> facteur de confiance dans [0.5, 1.0]
      double facteurConfiance = 0.5 + (MathAbs(scoreIQM) / 2.0);
      facteurConfiance = MathMax(0.5, MathMin(1.0, facteurConfiance));

      double risqueAjuste = risqueMonetaireBase * facteurConfiance;

      // Calcul de la perte pour 1 lot via OrderCalcProfit (gestion native devise du compte)
      double currentPrice = SymbolInfoDouble(m_symbole, SYMBOL_ASK);
      if(currentPrice <= 0.0) currentPrice = 1000.0; // Securite
      
      double profitPerLot = 0.0;
      bool success = OrderCalcProfit(ORDER_TYPE_BUY, m_symbole, 1.0, currentPrice, currentPrice - slDistancePrix, profitPerLot);
      
      double perteParLot = 0.0;
      if(success && profitPerLot < 0.0)
      {
         perteParLot = MathAbs(profitPerLot);
      }
      else
      {
         // Fallback si OrderCalcProfit echoue
         double tailleContrat = SymbolInfoDouble(m_symbole, SYMBOL_TRADE_CONTRACT_SIZE);
         if(tailleContrat <= 0.0) tailleContrat = 100.0; // securite
         perteParLot = slDistancePrix * tailleContrat;
      }

      if(perteParLot <= 0.0) return 0.0;

      double lot = risqueAjuste / perteParLot;

      return NormaliserVolume(lot);
   }

   //--- Borne le lot aux contraintes du symbole (min/max/pas), sinon le
   //    broker rejette l'ordre avec le code 10014 (invalid volume).
   //    Retourne 0.0 si le lot calcule est inferieur au minimum autorise
   //    (dans ce cas Execution n'ouvre pas la position).
   double NormaliserVolume(double lot)
   {
      double volMin  = SymbolInfoDouble(m_symbole, SYMBOL_VOLUME_MIN);
      double volMax  = SymbolInfoDouble(m_symbole, SYMBOL_VOLUME_MAX);
      double volStep = SymbolInfoDouble(m_symbole, SYMBOL_VOLUME_STEP);

      if(volStep <= 0.0) volStep = 0.01; // securite si le broker ne renseigne pas le pas

      // Arrondi au pas de volume le plus proche (vers le bas, prudence)
      // On ajoute 1e-9 pour eviter les erreurs d'arrondi ou MathFloor(0.01/0.01) => 0
      lot = MathFloor(lot / volStep + 1e-9) * volStep;

      if(lot < volMin) return 0.0;      // trop petit -> pas de trade (plutot que forcer volMin)
      if(lot > volMax) lot = volMax;    // plafonne au maximum autorise

      // Normalise au nombre de decimales du pas (evite les erreurs d'arrondi flottant)
      int decimales = 0;
      double temp = volStep;
      while(temp < 1.0 && decimales < 8)
      {
         temp *= 10.0;
         decimales++;
      }
      return NormalizeDouble(lot, decimales);
   }
};
