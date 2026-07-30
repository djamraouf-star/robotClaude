//+------------------------------------------------------------------+
//| CExecution.mqh                                                    |
//| Coordonne IQM, Filtres, MoteurProbabiliste (via CFichierCalibration),|
//| Logger, RiskManagement et ModuleOrdres. Ne trade jamais elle-meme  |
//| directement -- delegue tout a ModuleOrdres.                        |
//|                                                                    |
//| ArbitrerSignaux() implemente l'arbre de decision valide :          |
//| sequence IQM/Filtres en premier, puis garde RiskManagement,        |
//| puis action (DeclencherOrdre).                                     |
//|                                                                    |
//| CORRECTION (investigation "0 short en marche baissier") :          |
//| CFiltres.TendanceOK/MomentumOK/VolumeOK/VolatiliteOK prennent      |
//| desormais un parametre direction (+1/-1), pour juger un bucket     |
//| favorable dans le bon sens (au-dessus de la base pour un signal    |
//| haussier, en-dessous pour un signal baissier). Avant cette          |
//| correction, le garde-fou signalFiltres exigeait toujours des        |
//| buckets "favorables a la hausse", meme quand IQM avait detecte un  |
//| signal baissier valide -- ce qui bloquait systematiquement tout    |
//| short avant meme d'atteindre DeclencherOrdre().                    |
//+------------------------------------------------------------------+
#property strict
#include <ScalpOr/CIQM.mqh>
#include <ScalpOr/CFiltres.mqh>
#include <ScalpOr/CFichierCalibration.mqh>
#include <ScalpOr/CLogger.mqh>
#include <ScalpOr/CRiskManagement.mqh>
#include <ScalpOr/CModuleOrdres.mqh>
#include <ScalpOr/CIndicateurs.mqh>

class CExecution
{
private:
   CIQM                 *m_iqm;
   CFiltres             *m_filtres;
   CFichierCalibration  *m_calibration;
   CLogger              *m_logger;
   CRiskManagement      *m_risk;
   CModuleOrdres        *m_ordres;
   CIndicateurs         *m_indicateurs; // partagee avec IQM et Filtres, plus de handle propre

   string m_symbole;
   double m_multipleATR_SLTP;
   double m_margeSignalIQM; // marge minimale au-dessus de la proba de base pour un signal
   int    m_directionPosition; // 1 = achat, -1 = vente, 0 = aucune position
   datetime m_derniereBougieM1; // heure de la derniere bougie M1 traitee (1 execution/bougie)

   // Etats de marche au moment de l'ouverture
   int    m_regimeOuverture;
   int    m_bRSIOuverture;
   int    m_bADXOuverture;
   int    m_bATROuverture;
   int    m_bOBVOuverture;

   double CalculerExpositionPourcent()
   {
      // TODO : calcul reel de l'exposition engagee. Placeholder simple
      // (marge utilisee / equity) -- a affiner selon votre définition
      // exacte d'"exposition" (nb de lots, corrélation entre positions...).
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity <= 0.0) return 100.0; // prudence si donnee indisponible
      return (AccountInfoDouble(ACCOUNT_MARGIN) / equity) * 100.0;
   }

   double CalculerDrawdownJournalier()
   {
      //--- Debut de journee (heure serveur) : perte nette cumulee depuis
      //    minuit, via Logger -- capture l'accumulation reelle, y compris
      //    un motif "grosse perte, petit gain, grosse perte" que le
      //    circuit breaker (base sur des pertes CONSECUTIVES) ne verrait pas.
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      datetime debutJournee = StructToTime(dt);

      double resultatNetJour = m_logger.ObtenirResultatNetCumule(debutJournee);
      if(resultatNetJour >= 0.0) return 0.0; // pas de drawdown si journee positive ou neutre

      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity <= 0.0) return 100.0; // prudence si donnee indisponible

      return MathAbs(resultatNetJour) / equity * 100.0;
   }

   //--- Lecture ATR desormais deleguee a CIndicateurs (partagee avec
   //    IQM/Filtres) -- plus de handle cree/libere a chaque appel.
   double ObtenirATRCourant()
   {
      return m_indicateurs.ATR(1);
   }

   //--- Resultat net reel du trade (profit + swap + commission, tous les
   //    deals lies au ticket -- une position peut avoir plusieurs deals
   //    en cas de fermeture partielle). Retourne en devise du compte, pas
   //    en pips -- a convertir si vous avez besoin de pips precisement.
   double ObtenirResultatReel(ulong ticket)
   {
      double resultat = 0.0;
      if(!HistorySelectByPosition(ticket)) return 0.0;

      int nbDeals = HistoryDealsTotal();
      for(int i = 0; i < nbDeals; i++)
      {
         ulong dealTicket = HistoryDealGetTicket(i);
         resultat += HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
         resultat += HistoryDealGetDouble(dealTicket, DEAL_SWAP);
         resultat += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      }
      return resultat;
   }

public:
   CExecution(CIQM *iqm, CFiltres *filtres, CFichierCalibration *calibration,
              CLogger *logger, CRiskManagement *risk, CModuleOrdres *ordres,
              CIndicateurs *indicateurs, string symbole = "GOLD", double multipleATR_SLTP = 1.0,
              double margeSignalIQM = 0.05)
   {
      m_iqm = iqm;
      m_filtres = filtres;
      m_calibration = calibration;
      m_logger = logger;
      m_risk = risk;
      m_ordres = ordres;
      m_indicateurs = indicateurs;
      m_symbole = symbole;
      m_multipleATR_SLTP = multipleATR_SLTP;
      m_margeSignalIQM = margeSignalIQM;
      m_directionPosition = 0;
      m_derniereBougieM1 = 0;
   }

   //--- Point d'entree appele a chaque tick par l'EA (OnTick).
   //    La gestion de position et la cloture doivent etre evaluees a chaque
   //    tick, mais la recherche de nouveaux signaux (ArbitrerSignaux)
   //    ne s'execute qu'UNE FOIS par nouvelle bougie M1 cloturee.
   void Coordonner()
   {
      ENUM_ETAT_ORDRE etat = m_ordres.EtatActuel();

      // Gestion a chaque tick si une position est ouverte (trailing SL, etc.)
      if(etat == ETAT_POSITION_OUVERTE)
      {
         GererPositionOuverte();
         etat = m_ordres.EtatActuel(); // reactualise l'etat au cas ou il vient de changer
      }

      // Finalisation immediate des qu'une cloture est detectee
      if(etat == ETAT_CLOTUREE)
      {
         FinaliserCloture();
         etat = m_ordres.EtatActuel();
      }

      // Detection de signaux uniquement sur nouvelle bougie (shift 1)
      datetime tBougieCourante = iTime(m_symbole, PERIOD_M1, 0);
      if(tBougieCourante != m_derniereBougieM1)
      {
         m_derniereBougieM1 = tBougieCourante;
         if(etat == ETAT_IDLE)
         {
            ArbitrerSignaux();
         }
      }
   }

   //--- Arbre de decision valide : IQM/Filtres (sequence), puis
   //    RiskManagement (garde/veto), puis action
   void ArbitrerSignaux()
   {
      //--- Signal directionnel calibre : +1 haussier, -1 baissier, 0 neutre.
      //    Le seuil est une marge INTERPRETABLE au-dessus de la proba de base
      //    (m_margeSignalIQM), pas un seuil sur le score brut.
      int direction = m_iqm.SignalDirectionnel(m_margeSignalIQM);
      if(direction == 0) return; // etat inconnu ou trop proche du hasard

      double scoreIQM = m_iqm.CalculerScore(); // conserve pour le sizing et le log

      //--- CORRECTION : les 4 filtres jugent desormais la favorabilite DANS
      //    LE SENS DE "direction" (au-dessus de la base pour un signal
      //    haussier, en-dessous pour un signal baissier). Avant, ils
      //    exigeaient toujours "au-dessus de la base", ce qui bloquait
      //    structurellement tout signal baissier.
      bool signalFiltres = m_filtres.TendanceOK(direction) && m_filtres.MomentumOK(direction) &&
                            m_filtres.VolumeOK(direction) && m_filtres.VolatiliteOK(direction);

      if(!signalFiltres) return; // rien a faire ce tick

      int regime, bRSI, bADX, bATR, bOBV;
      m_iqm.ObtenirEtatMarche(regime, bRSI, bADX, bATR, bOBV);
      datetime idCalib = m_calibration.ObtenirDerniereRecharge();

      //--- Garde 1 : circuit breaker (pertes consecutives, via Logger)
      int pertesConsecutives = m_logger.CompterPertesConsecutives();
      SResultatVerification resCircuit = m_risk.AppliquerCircuitBreaker(pertesConsecutives);
      if(!resCircuit.autorise)
      {
         m_logger.EnregistrerSignalRejete(idCalib, TimeCurrent(), regime, bRSI, bADX, bATR, bOBV,
                                           scoreIQM, resCircuit.motif);
         return;
      }

      //--- Garde 2 : exposition
      int nbPositions = PositionsTotal();
      SResultatVerification resExposition = m_risk.VerifierExposition(nbPositions, CalculerExpositionPourcent());
      if(!resExposition.autorise)
      {
         m_logger.EnregistrerSignalRejete(idCalib, TimeCurrent(), regime, bRSI, bADX, bATR, bOBV,
                                           scoreIQM, resExposition.motif);
         return;
      }

      //--- Garde 3 : drawdown journalier (accumulation nette reelle depuis
      //    minuit, signal independant du circuit breaker)
      SResultatVerification resDrawdown = m_risk.VerifierDrawdownJournalier(CalculerDrawdownJournalier());
      if(!resDrawdown.autorise)
      {
         m_logger.EnregistrerSignalRejete(idCalib, TimeCurrent(), regime, bRSI, bADX, bATR, bOBV,
                                           scoreIQM, resDrawdown.motif);
         return;
      }

      //--- Tout est valide : declenchement de l'ordre dans la direction du signal
      DeclencherOrdre(direction, scoreIQM, regime, bRSI, bADX, bATR, bOBV);
   }

   //--- Action finale de l'arbre : calcule lot/SL/TP, valide le signal
   //    (transition FSM Idle -> SignalValide), puis ouvre la position.
   //    direction (+1/-1) vient de IQM.SignalDirectionnel, scoreIQM sert
   //    uniquement au sizing (CalculerTailleLot) et n'impose plus le sens.
   void DeclencherOrdre(int direction, double scoreIQM, int regime, int bRSI, int bADX, int bATR, int bOBV)
   {
      double atrCourant = ObtenirATRCourant();
      if(atrCourant <= 0.0) return;

      // Distance du SL en PRIX (l'ATR est deja en prix, pas en points)
      double slDistancePrix = atrCourant * m_multipleATR_SLTP;
      double capitalDisponible = AccountInfoDouble(ACCOUNT_EQUITY);

      double lot = m_risk.CalculerTailleLot(scoreIQM, capitalDisponible, slDistancePrix);
      if(lot <= 0.0) return;

      ENUM_ORDER_TYPE type;
      double sl, tp, prixActuel;

      if(direction > 0)
      {
         type = ORDER_TYPE_BUY;
         prixActuel = SymbolInfoDouble(m_symbole, SYMBOL_ASK);
         sl = prixActuel - slDistancePrix;
         tp = prixActuel + slDistancePrix;
         m_directionPosition = 1;
      }
      else
      {
         type = ORDER_TYPE_SELL;
         prixActuel = SymbolInfoDouble(m_symbole, SYMBOL_BID);
         sl = prixActuel + slDistancePrix;
         tp = prixActuel - slDistancePrix;
         m_directionPosition = -1;
      }

// >>> AJOUT DIAGNOSTIC
      Print("ENTREE ", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
            " dir=", direction,
            " prix=", DoubleToString(prixActuel, _Digits),
            " RSI=", DoubleToString(m_indicateurs.RSI(1), 2),
            " ADX=", DoubleToString(m_indicateurs.ADX(1), 2),
            " ATR=", DoubleToString(atrCourant, 5));
      // <<< FIN AJOUT

      m_ordres.ValiderSignal();
      if(m_ordres.OuvrirPosition(type, lot, sl, tp))
      {
         // Mémorise les conditions exactes d'ouverture pour le log à la clôture
         m_regimeOuverture = regime;
         m_bRSIOuverture = bRSI;
         m_bADXOuverture = bADX;
         m_bATROuverture = bATR;
         m_bOBVOuverture = bOBV;
      }
      else
      {
         m_directionPosition = 0; // echec d'ouverture, on annule la direction retenue
      }
   }

   //--- Position ouverte : suivi + detection de retournement (les DEUX
   //    signaux requis, cf. decision sur la FSM de ModuleOrdres)
   void GererPositionOuverte()
   {
      double scoreIQM = m_iqm.CalculerScore();
      bool retournementIQM = (m_directionPosition == 1 && scoreIQM < 0.0) ||
                              (m_directionPosition == -1 && scoreIQM > 0.0);

      // TODO : la definition exacte de "retournement Filtres" reste a
      // valider -- ici, on considere que Tendance ou Momentum qui ne
      // sont plus OK (dans le sens de la position ouverte, m_directionPosition)
      // constitue un retournement.
      bool retournementFiltres = !(m_filtres.TendanceOK(m_directionPosition) &&
                                    m_filtres.MomentumOK(m_directionPosition));

      double atrCourant = ObtenirATRCourant();
      m_ordres.SuivrePosition(retournementIQM, retournementFiltres, atrCourant, m_multipleATR_SLTP);
   }

   //--- Cloture -> log -> reinitialisation, dans cet ordre impose
   //    (cf. decision sur CModuleOrdres.Reinitialiser)
   void FinaliserCloture()
   {
      double resultatMonetaire = ObtenirResultatReel(m_ordres.ObtenirTicket());
      // TODO : resultatR (multiple du risque initial) necessiterait de
      // conserver le risque monetaire calcule a l'ouverture (CalculerTailleLot)
      // -- pas encore stocke entre l'ouverture et la cloture, laisse a 0.0.

      m_logger.EnregistrerTrade(m_calibration.ObtenirDerniereRecharge(),
                                 m_ordres.ObtenirTempsOuverture(), TimeCurrent(),
                                 resultatMonetaire, 0.0,
                                 m_regimeOuverture, m_bRSIOuverture, m_bADXOuverture, m_bATROuverture, m_bOBVOuverture);

      m_ordres.Reinitialiser();
      m_directionPosition = 0;
   }
};
