//+------------------------------------------------------------------+
//| CFichierCalibration.mqh                                          |
//| Charge calibration.csv et poids_indicateurs.csv (produits par     |
//| ScalpOr_MoteurProbabiliste.mq5) et les rend consommables par      |
//| IQM et Filtres.                                                    |
//|                                                                    |
//| Utilisee par l'EA en temps reel : OnInit() -> Charger() une fois,  |
//| puis OnTimer() -> VerifierDate() + Charger() si rechargement       |
//| necessaire (cf. logique de fenetre horaire calme).                 |
//+------------------------------------------------------------------+
#property strict

//--- Meme enum que MoteurProbabiliste, pour rester coherent cote lecture
enum ENUM_TYPE_INDICATEUR { TYPE_RSI, TYPE_ADX, TYPE_ATR, TYPE_OBV };

//--- Une ligne de calibration.csv
struct SEntreeCalibration
{
   int    regime;
   int    bucketRSI;
   int    bucketADX;
   int    bucketATR;
   int    bucketOBV;
   long   occurrences;
   long   favorables;
   long   defavorables;
   long   exclusions;
   double probabilite;
};

class CFichierCalibration
{
private:
   string               m_dossier;              // ex. "ScalpOr"
   SEntreeCalibration   m_table[];               // contenu de calibration.csv
   double               m_poids[4];              // 0=RSI,1=ADX,2=ATR,3=OBV
   double               m_tercileATR[2];         // seuils bas/moyen, moyen/eleve
   double               m_probaBase;             // probabilite marginale globale
   double               m_margRSI[3];            // probabilite marginale par bucket isole
   double               m_margADX[2];
   double               m_margATR[3];
   double               m_margOBV[2];
   double               m_margRegime[3];         // index 0=baissier,1=neutre,2=haussier
   datetime             m_derniereModifCalib;    // date de derniere lecture reussie
   datetime             m_derniereModifPoids;
   datetime             m_derniereModifMarginales;
   bool                 m_charge;

   string CheminCalibration() const { return m_dossier + "\\calibration.csv"; }
   string CheminPoids()       const { return m_dossier + "\\poids_indicateurs.csv"; }
   string CheminMarginales()  const { return m_dossier + "\\seuils_filtres.csv"; }

   //--- Date de modification d'un fichier du dossier COMMUN. FileGetInteger
   //    a 2 arguments ne cible que le dossier local du terminal, pas le
   //    commun -- on passe donc par un handle ouvert avec FILE_COMMON.
   datetime DateModif(string chemin)
   {
      int h = FileOpen(chemin, FILE_READ | FILE_CSV | FILE_ANSI | FILE_COMMON, ';');
      if(h == INVALID_HANDLE) return 0;
      datetime d = (datetime)FileGetInteger(h, FILE_MODIFY_DATE);
      FileClose(h);
      return d;
   }

   bool ChargerCalibration()
   {
      int handle = FileOpen(CheminCalibration(), FILE_READ | FILE_CSV | FILE_ANSI | FILE_COMMON, ';');
      if(handle == INVALID_HANDLE)
      {
         Print("CFichierCalibration : impossible d'ouvrir ", CheminCalibration());
         return false;
      }

      ArrayResize(m_table, 0);

      // Ligne d'en-tete : on la consomme sans l'utiliser
      for(int c = 0; c < 10 && !FileIsEnding(handle); c++)
         FileReadString(handle);

      int n = 0;
      while(!FileIsEnding(handle))
      {
         SEntreeCalibration e;
         e.regime       = (int)StringToInteger(FileReadString(handle));
         e.bucketRSI    = (int)StringToInteger(FileReadString(handle));
         e.bucketADX    = (int)StringToInteger(FileReadString(handle));
         e.bucketATR    = (int)StringToInteger(FileReadString(handle));
         e.bucketOBV    = (int)StringToInteger(FileReadString(handle));
         e.occurrences  = StringToInteger(FileReadString(handle));
         e.favorables   = StringToInteger(FileReadString(handle));
         e.defavorables = StringToInteger(FileReadString(handle));
         e.exclusions   = StringToInteger(FileReadString(handle));
         e.probabilite  = StringToDouble(FileReadString(handle));

         if(FileIsEnding(handle) && e.occurrences == 0) break; // derniere ligne vide

         ArrayResize(m_table, n + 1);
         m_table[n] = e;
         n++;
      }

      FileClose(handle);
      Print("CFichierCalibration : ", n, " etats charges depuis calibration.csv");
      return true;
   }

   bool ChargerPoids()
   {
      int handle = FileOpen(CheminPoids(), FILE_READ | FILE_CSV | FILE_ANSI | FILE_COMMON, ';');
      if(handle == INVALID_HANDLE)
      {
         Print("CFichierCalibration : impossible d'ouvrir ", CheminPoids());
         return false;
      }

      // En-tete
      FileReadString(handle);
      FileReadString(handle);

      while(!FileIsEnding(handle))
      {
         string nom = FileReadString(handle);
         if(nom == "") break;
         double valeur = StringToDouble(FileReadString(handle));

         if(nom == "RSI") m_poids[TYPE_RSI] = valeur;
         else if(nom == "ADX") m_poids[TYPE_ADX] = valeur;
         else if(nom == "ATR") m_poids[TYPE_ATR] = valeur;
         else if(nom == "OBV") m_poids[TYPE_OBV] = valeur;
         else if(nom == "ATR_Tercile_Bas")  m_tercileATR[0] = valeur;
         else if(nom == "ATR_Tercile_Haut") m_tercileATR[1] = valeur;
         else if(nom == "ProbaBase")        m_probaBase = valeur;
      }

      FileClose(handle);
      Print("CFichierCalibration : poids charges -> RSI=", m_poids[TYPE_RSI],
            " ADX=", m_poids[TYPE_ADX], " ATR=", m_poids[TYPE_ATR], " OBV=", m_poids[TYPE_OBV]);
      return true;
   }

   bool ChargerMarginales()
   {
      int handle = FileOpen(CheminMarginales(), FILE_READ | FILE_CSV | FILE_ANSI | FILE_COMMON, ';');
      if(handle == INVALID_HANDLE)
      {
         Print("CFichierCalibration : impossible d'ouvrir ", CheminMarginales());
         return false;
      }

      // En-tete (3 champs)
      FileReadString(handle); FileReadString(handle); FileReadString(handle);

      while(!FileIsEnding(handle))
      {
         string nom = FileReadString(handle);
         if(nom == "") break;
         int    bucket = (int)StringToInteger(FileReadString(handle));
         double valeur = StringToDouble(FileReadString(handle));

         if(nom == "RSI" && bucket >= 0 && bucket < 3) m_margRSI[bucket] = valeur;
         else if(nom == "ADX" && bucket >= 0 && bucket < 2) m_margADX[bucket] = valeur;
         else if(nom == "ATR" && bucket >= 0 && bucket < 3) m_margATR[bucket] = valeur;
         else if(nom == "OBV" && bucket >= 0 && bucket < 2) m_margOBV[bucket] = valeur;
         else if(nom == "REGIME" && bucket >= -1 && bucket <= 1) m_margRegime[bucket + 1] = valeur;
      }

      FileClose(handle);
      Print("CFichierCalibration : marginales chargees depuis seuils_filtres.csv");
      return true;
   }

public:
   CFichierCalibration(string dossier = "ScalpOr")
   {
      m_dossier = dossier;
      m_charge = false;
      m_derniereModifCalib = 0;
      m_derniereModifPoids = 0;
      m_derniereModifMarginales = 0;
      ArrayInitialize(m_poids, 0.25); // poids egaux par defaut tant que rien n'est charge
      m_tercileATR[0] = 0.0;
      m_tercileATR[1] = 0.0;
      m_probaBase = 0.5;
      ArrayInitialize(m_margRSI, -1.0);
      ArrayInitialize(m_margADX, -1.0);
      ArrayInitialize(m_margATR, -1.0);
      ArrayInitialize(m_margOBV, -1.0);
      ArrayInitialize(m_margRegime, -1.0);
   }

   //--- Charge (ou recharge) les deux fichiers en memoire
   bool Charger()
   {
      bool okCalib = ChargerCalibration();
      bool okPoids = ChargerPoids();
      bool okMarg  = ChargerMarginales();

      if(okCalib && okPoids && okMarg)
      {
         m_derniereModifCalib     = DateModif(CheminCalibration());
         m_derniereModifPoids     = DateModif(CheminPoids());
         m_derniereModifMarginales = DateModif(CheminMarginales());
         m_charge = true;
      }
      return (okCalib && okPoids && okMarg);
   }

   //--- Indique si l'un des trois fichiers a change depuis le dernier Charger()
   //    (a utiliser dans OnTimer, avant de decider une bascule)
   bool VerifierDate()
   {
      if(!m_charge) return true; // jamais charge -> considere comme "change"

      datetime modifCalib = DateModif(CheminCalibration());
      datetime modifPoids = DateModif(CheminPoids());
      datetime modifMarg  = DateModif(CheminMarginales());

      return (modifCalib != m_derniereModifCalib || modifPoids != m_derniereModifPoids ||
              modifMarg != m_derniereModifMarginales);
   }

   //--- Probabilite associee a un etat (regime + 4 buckets)
   //    Retourne -1.0 si l'etat n'existe pas dans la table (sous-echantillonne
   //    ou jamais rencontre a la calibration -> a IQM de decider quoi faire)
   double ObtenirProbabilite(int regime, int bucketRSI, int bucketADX, int bucketATR, int bucketOBV)
   {
      int n = ArraySize(m_table);
      for(int i = 0; i < n; i++)
      {
         if(m_table[i].regime == regime && m_table[i].bucketRSI == bucketRSI &&
            m_table[i].bucketADX == bucketADX && m_table[i].bucketATR == bucketATR &&
            m_table[i].bucketOBV == bucketOBV)
            return m_table[i].probabilite;
      }
      return -1.0; // etat inconnu
   }

   //--- Poids normalise d'un indicateur (pour la somme ponderee de l'IQM)
   double ObtenirPoids(ENUM_TYPE_INDICATEUR type)
   {
      return m_poids[type];
   }

   //--- Terciles ATR utilises a la calibration (memes seuils a reutiliser
   //    en temps reel, sinon les buckets ATR d'IQM ne correspondent plus
   //    a ceux de calibration.csv)
   void ObtenirTercilesATR(double &terciles[])
   {
      ArrayResize(terciles, 2);
      terciles[0] = m_tercileATR[0];
      terciles[1] = m_tercileATR[1];
   }

   //--- Probabilite marginale d'un bucket isole (pour CFiltres, qui juge
   //    un indicateur a la fois -> retourne -1 si bucket jamais rencontre)
   double ObtenirProbabiliteMarginale(ENUM_TYPE_INDICATEUR type, int bucket)
   {
      switch(type)
      {
         case TYPE_RSI: return (bucket >= 0 && bucket < 3) ? m_margRSI[bucket] : -1.0;
         case TYPE_ADX: return (bucket >= 0 && bucket < 2) ? m_margADX[bucket] : -1.0;
         case TYPE_ATR: return (bucket >= 0 && bucket < 3) ? m_margATR[bucket] : -1.0;
         case TYPE_OBV: return (bucket >= 0 && bucket < 2) ? m_margOBV[bucket] : -1.0;
      }
      return -1.0;
   }

   //--- Probabilite de base globale (reference pour juger si un bucket
   //    isole est favorable ou non, cf. CFiltres)
   double ObtenirProbabiliteBase() const { return m_probaBase; }

   //--- Date de la derniere recharge reussie de calibration.csv (utilisee
   //    par CLogger.VerifierStaleness() pour detecter un rechargement
   //    silencieusement bloque)
   datetime ObtenirDerniereRecharge() const { return m_derniereModifCalib; }

   //--- Probabilite marginale d'un regime isole (-1, 0, 1), pour
   //    CFiltres.TendanceOK()
   double ObtenirProbabiliteMarginaleRegime(int regime)
   {
      if(regime < -1 || regime > 1) return -1.0;
      return m_margRegime[regime + 1];
   }

   bool EstCharge() const { return m_charge; }
   int  NombreEtats() const { return ArraySize(m_table); }
};
