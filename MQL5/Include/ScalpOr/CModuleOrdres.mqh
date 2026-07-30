//+------------------------------------------------------------------+
//| CModuleOrdres.mqh                                                  |
//| FSM a 5 etats : Idle -> SignalValide -> PositionOuverte ->         |
//| SortieAnticipee -> Cloturee -> (retour) Idle.                      |
//|                                                                    |
//| SortieAnticipee : etat a part entiere, declenchee uniquement si    |
//| IQM ET Filtres indiquent tous les deux un retournement (pas un     |
//| seul des deux) -> cloture immediate au marche, non annulable.      |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

enum ENUM_ETAT_ORDRE
{
   ETAT_IDLE,
   ETAT_SIGNAL_VALIDE,
   ETAT_POSITION_OUVERTE,
   ETAT_SORTIE_ANTICIPEE,
   ETAT_CLOTUREE
};

class CModuleOrdres
{
private:
   CTrade          m_trade;
   string          m_symbole;
   ENUM_ETAT_ORDRE m_etat;
   ulong           m_ticketPosition;
   datetime        m_tOuverture;
   double          m_pasTrailingATR; // le SL ne bouge que si le prix gagne au moins ce multiple d'ATR

public:
   CModuleOrdres(string symbole = "GOLD", double pasTrailingATR = 0.5)
   {
      m_symbole = symbole;
      m_etat = ETAT_IDLE;
      m_ticketPosition = 0;
      m_tOuverture = 0;
      m_pasTrailingATR = pasTrailingATR;
   }

   ENUM_ETAT_ORDRE EtatActuel() const { return m_etat; }

   //--- Transition Idle -> SignalValide (appelee par Execution.ArbitrerSignaux
   //    une fois la sequence IQM/Filtres/RiskManagement passee avec succes)
   bool ValiderSignal()
   {
      if(m_etat != ETAT_IDLE) return false;
      m_etat = ETAT_SIGNAL_VALIDE;
      return true;
   }

   //--- Transition SignalValide -> PositionOuverte
   bool OuvrirPosition(ENUM_ORDER_TYPE type, double lot, double sl, double tp)
   {
      if(m_etat != ETAT_SIGNAL_VALIDE) return false;

      bool ok = (type == ORDER_TYPE_BUY)
                ? m_trade.Buy(lot, m_symbole, 0.0, sl, tp)
                : m_trade.Sell(lot, m_symbole, 0.0, sl, tp);

      if(ok)
      {
         m_ticketPosition = m_trade.ResultOrder();
         m_tOuverture = TimeCurrent();
         m_etat = ETAT_POSITION_OUVERTE;
      }
      else
      {
         Print("CModuleOrdres : echec OuvrirPosition, code retour=", m_trade.ResultRetcode());
         m_etat = ETAT_IDLE; // le signal valide n'a pas abouti, on repart de zero
      }

      return ok;
   }

   //--- A appeler a chaque tick tant que l'etat est PositionOuverte.
   //    Gere le SL/TP dynamique ET verifie le retournement (double mode
   //    de sortie, cf. decision d'origine sur le combo SuperTrend/ATR).
   //    retournementIQM et retournementFiltres sont fournis par Execution
   //    (ce module ne consulte pas IQM/Filtres directement).
   void SuivrePosition(bool retournementIQM, bool retournementFiltres, double atrCourant, double multipleATR_SLTP)
   {
      if(m_etat != ETAT_POSITION_OUVERTE) return;

      //--- La position peut avoir ete cloturee cote broker (SL/TP touche)
      //    sans passer par notre ClorePosition() -- sans cette verification,
      //    la FSM resterait bloquee en PositionOuverte indefiniment.
      if(!PositionSelectByTicket(m_ticketPosition))
      {
         m_etat = ETAT_CLOTUREE;
         return;
      }

      GererSLTP(atrCourant, multipleATR_SLTP);

      //--- Sortie anticipee seulement si les DEUX signalent un retournement
      //    (cf. decision : ni IQM seul, ni Filtres seul, ne suffit)
      if(retournementIQM && retournementFiltres)
      {
         m_etat = ETAT_SORTIE_ANTICIPEE;
         ClorePosition();
      }
   }

   //--- SL/TP dynamique base sur l'ATR courant
   //--- Trailing stop base sur l'ATR : le SL ne fait qu'AVANCER dans le
   //    sens du profit (jamais reculer), et n'est modifie que si le
   //    deplacement est reel et respecte la distance minimale imposee par
   //    le broker (SYMBOL_TRADE_STOPS_LEVEL). Sans ces deux conditions, MT5
   //    rejette la modification en boucle avec [invalid stops].
   void GererSLTP(double atrCourant, double multipleATR)
   {
      if(m_etat != ETAT_POSITION_OUVERTE) return;
      if(!PositionSelectByTicket(m_ticketPosition)) return;
      if(atrCourant <= 0.0) return;

      long   typePosition = PositionGetInteger(POSITION_TYPE);
      double slActuel     = PositionGetDouble(POSITION_SL);
      double tpActuel     = PositionGetDouble(POSITION_TP);

      double point       = SymbolInfoDouble(m_symbole, SYMBOL_POINT);
      long   stopsLevel  = SymbolInfoInteger(m_symbole, SYMBOL_TRADE_STOPS_LEVEL);
      double distanceMin = stopsLevel * point; // distance mini prix<->SL exigee par le broker
      double distanceATR = atrCourant * multipleATR;
      double pasMin      = atrCourant * m_pasTrailingATR; // deplacement mini pour bouger le SL

      double nouveauSL;

      if(typePosition == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(m_symbole, SYMBOL_BID);
         nouveauSL = bid - distanceATR;
         // Respecte la distance mini et ne recule jamais le SL existant
         if(bid - nouveauSL < distanceMin) return;
         // Ne bouge que si le SL avance d'au moins le pas minimum (evite de
         // remodifier a chaque tick -> backtest lent + SL trop serre)
         if(slActuel > 0.0 && nouveauSL - slActuel < pasMin) return;

         ModifierPositionAvecRetry(m_ticketPosition, nouveauSL, tpActuel);
      }
      else // SELL
      {
         double ask = SymbolInfoDouble(m_symbole, SYMBOL_ASK);
         nouveauSL = ask + distanceATR;
         if(nouveauSL - ask < distanceMin) return;
         if(slActuel > 0.0 && slActuel - nouveauSL < pasMin) return;

         ModifierPositionAvecRetry(m_ticketPosition, nouveauSL, tpActuel);
      }
   }

   //--- Retry pour PositionModify
   bool ModifierPositionAvecRetry(ulong ticket, double sl, double tp)
   {
      bool ok = false;
      int maxRetries = 3;
      for(int i = 0; i < maxRetries; i++)
      {
         ok = m_trade.PositionModify(ticket, sl, tp);
         if(ok) break;
         
         uint retcode = m_trade.ResultRetcode();
         Print("CModuleOrdres : echec PositionModify (", i+1, "/", maxRetries, "), code=", retcode);
         if(retcode == 10004 || retcode == 10009 || retcode == 10015 || retcode == 10016 || retcode == 10025)
         {
            Sleep(100);
         }
         else
         {
            break;
         }
      }
      if(!ok) Print("CModuleOrdres : echec PositionModify pour ticket ", ticket, " code=", m_trade.ResultRetcode(), " echoue definitivement !");
      return ok;
   }

   //--- Transition PositionOuverte/SortieAnticipee -> Cloturee.
   //    Cloture immediate au marche, jamais annulable (cf. decision).
   bool ClorePosition()
   {
      if(m_etat != ETAT_POSITION_OUVERTE && m_etat != ETAT_SORTIE_ANTICIPEE) return false;
      
      bool ok = false;
      int maxRetries = 3;
      for(int i = 0; i < maxRetries; i++)
      {
         ok = m_trade.PositionClose(m_ticketPosition);
         if(ok) break;
         
         uint retcode = m_trade.ResultRetcode();
         Print("CModuleOrdres : echec PositionClose (", i+1, "/", maxRetries, "), code=", retcode);
         if(retcode == 10004 || retcode == 10009 || retcode == 10015 || retcode == 10016 || retcode == 10025)
         {
            Sleep(100);
         }
         else
         {
            break;
         }
      }

      if(ok) m_etat = ETAT_CLOTUREE;
      else Print("CModuleOrdres : ClorePosition a echoue definitivement ! L'etat reste bloque sur ", EnumToString(m_etat));
      return ok;
   }

   //--- Transition Cloturee -> Idle. A appeler par Execution APRES que
   //    Logger.EnregistrerTrade() a bien enregistre le resultat -- l'ordre
   //    des operations est de la responsabilite d'Execution, pas de ce module.
   void Reinitialiser()
   {
      if(m_etat != ETAT_CLOTUREE) return;
      m_etat = ETAT_IDLE;
      m_ticketPosition = 0;
      m_tOuverture = 0;
   }

   ulong    ObtenirTicket() const          { return m_ticketPosition; }
   datetime ObtenirTempsOuverture() const  { return m_tOuverture; }
};
