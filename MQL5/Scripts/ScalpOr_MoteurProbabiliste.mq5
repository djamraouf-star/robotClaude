//+------------------------------------------------------------------+
//| ScalpOr_MoteurProbabiliste.mq5                                    |
//| Script hors ligne : calcule les probabilites conditionnelles      |
//| de mouvement par etat de marche (regime M15 + etat fin M1)        |
//| et exporte une table de calibration (calibration.csv)             |
//|                                                                    |
//| NE PAS attacher a un graphique en tant qu'EA : ce script tourne    |
//| une seule fois sur l'historique, jamais en temps reel.            |
//+------------------------------------------------------------------+
#property script_show_inputs
#resource "\\Indicators\\ScalpOr\\SuperTrend.ex5"
#include <ScalpOr/CEncodageEtat.mqh>

//--- Parametres ajustables (calibration de la methodologie, pas de la strategie)
input string   SymboleCible            = "GOLD";       // Symbole a analyser
input datetime DateDebut               = D'2026.06.01';
input datetime DateFin                 = D'2026.06.30';
input double   MultipleATR_MouvementFav = 1.0;          // Cf. decision : ajustable via backtest
input int      PlafondBarresGardeFou    = 80;            // Fixe, non ajustable (garde-fou)
input int      SeuilMinEchantillon      = 40;            // 30-50, valeur de depart

//--- Buckets (granularite basse, decidee pour limiter la combinatoire)
// Regime M15 (SuperTrend) : 3 valeurs -> -1 baissier, 0 neutre, 1 haussier
// RSI M1     : 3 buckets   -> 0 bas (<40), 1 neutre (40-60), 2 haut (>60)
// ADX M1     : 2 buckets   -> 0 faible (<25), 1 fort (>=25)
// ATR M1     : 3 buckets   -> 0/1/2 par tercile (calcule sur la periode)
// OBV M1     : 2 buckets   -> 0 baissier, 1 haussier (pente sur N barres)

//--- Structure d'accumulation par etat (regime x etat fin)
struct SEtatStats
{
   int    regime;         // -1, 0, 1
   int    bucketRSI;      // 0-2
   int    bucketADX;      // 0-1
   int    bucketATR;      // 0-2
   int    bucketOBV;      // 0-1
   long   occurrences;
   long   favorables;     // mouvement favorable atteint avant defavorable
   long   defavorables;
   long   exclusions;     // plafond atteint sans mouvement -> exclu du ratio
};

#define MAX_ETATS 200
SEtatStats EtatsTable[MAX_ETATS];
int NbEtats = 0;

//--- Types d'indicateurs consideres pour le calcul de poids
//    (regime M15/SuperTrend exclu : role de contexte, pas de poids IQM)
//    NB : nommes TYPE_xxx (pas IND_xxx) pour eviter le conflit avec les
//    constantes natives ENUM_INDICATOR::IND_RSI/IND_ADX/IND_ATR/IND_OBV
enum ENUM_TYPE_INDICATEUR { TYPE_RSI, TYPE_ADX, TYPE_ATR, TYPE_OBV };
double PoidsIndicateurs[4]; // 0=RSI, 1=ADX, 2=ATR, 3=OBV, normalises (somme = 1)
double g_atrTerciles[2];    // seuils bas/moyen et moyen/eleve, reutilises par IQM
double g_probaBase;         // probabilite marginale globale (toutes conditions confondues)

//--- Probabilites marginales par bucket isole (necessaires a CFiltres,
//    qui evalue un indicateur a la fois, pas un etat complet comme IQM)
double MargRSI[3];
double MargADX[2];
double MargATR[3];
double MargOBV[2];
double MargRegime[3]; // index 0=baissier(-1), 1=neutre(0), 2=haussier(1)

//+------------------------------------------------------------------+
//| Probabilite marginale par regime M15 (pour CFiltres.TendanceOK)   |
//+------------------------------------------------------------------+
void CalculerMarginaleRegime(double &margOut[])
{
   ArrayResize(margOut, 3);
   ArrayInitialize(margOut, -1.0);

   for(int r = -1; r <= 1; r++)
   {
      long occR = 0, favR = 0, defavR = 0;
      for(int i = 0; i < NbEtats; i++)
      {
         if(EtatsTable[i].occurrences < SeuilMinEchantillon) continue;
         if(EtatsTable[i].regime != r) continue;

         occR   += EtatsTable[i].occurrences;
         favR   += EtatsTable[i].favorables;
         defavR += EtatsTable[i].defavorables;
      }
      long baseR = favR + defavR;
      if(baseR == 0) continue;

      margOut[r + 1] = (double)favR / baseR;
   }
}

//--- Handles d'indicateurs (MQL5 : iRSI/iADX/iATR/iMA/iOBV retournent un
//    handle, pas une valeur directe comme en MQL4 -> lecture via CopyBuffer)
int hRSI_M1        = INVALID_HANDLE;
int hADX_M1        = INVALID_HANDLE;
int hATR_M1        = INVALID_HANDLE;
int hOBV_M1        = INVALID_HANDLE;
int hSuperTrend_M15 = INVALID_HANDLE;

//--- Parametres du vrai SuperTrend (remplace le placeholder EMA50) --
//    memes valeurs par defaut que CIndicateurs.mqh, a garder synchronisees
input int    ATRPeriode_SuperTrend      = 10;  // Periode ATR du SuperTrend
input double Multiplicateur_SuperTrend  = 3.0; // Multiplicateur des bandes SuperTrend

//+------------------------------------------------------------------+
//| Lit une valeur d'indicateur (buffer 0) a un shift donne            |
//+------------------------------------------------------------------+
double ObtenirValeurIndicateur(int handle, int shift)
{
   double buffer[];
   ArraySetAsSeries(buffer, true);
   if(CopyBuffer(handle, 0, shift, 1, buffer) <= 0) return 0.0;
   return buffer[0];
}

//+------------------------------------------------------------------+
//| Attend que l'indicateur ait fini de calculer les barres requises   |
//+------------------------------------------------------------------+
bool AttendreCalculIndicateur(int handle, int barresRequises)
{
   int tentative = 0;
   while(BarsCalculated(handle) < barresRequises && tentative < 200)
   {
      Sleep(50);
      tentative++;
   }
   return (BarsCalculated(handle) >= barresRequises);
}

//+------------------------------------------------------------------+
//| Point d'entree du script                                          |
//+------------------------------------------------------------------+
void OnStart()
{
   Print("=== MoteurProbabiliste : demarrage calibration ===");

   //--- Force le chargement de l'historique sur la fenetre demandee :
   //    sur un graphique, MT5 ne charge les barres anciennes que si elles
   //    ont ete demandees. Sans ces appels, l'historique peut etre vide
   //    ou partiel au moment ou le script l'itere.
   datetime tmpM1[], tmpM15[];
   int copiesM1  = CopyTime(SymboleCible, PERIOD_M1,  DateDebut, DateFin, tmpM1);
   int copiesM15 = CopyTime(SymboleCible, PERIOD_M15, DateDebut, DateFin, tmpM15);
   Print("Historique charge : ", copiesM1, " barres M1, ", copiesM15, " barres M15 sur la fenetre demandee");

   if(copiesM1 <= 0)
   {
      Print("ERREUR : aucune barre M1 sur la fenetre ", TimeToString(DateDebut, TIME_DATE),
            " -> ", TimeToString(DateFin, TIME_DATE),
            ". Verifiez l'historique disponible (Outils > Centre de telechargement historique) ",
            "ou ajustez DateDebut/DateFin aux dates reellement couvertes.");
      return;
   }

   //--- Creation des handles d'indicateurs (obligatoire en MQL5)
   hRSI_M1 = iRSI(SymboleCible, PERIOD_M1, 14, PRICE_CLOSE);
   hADX_M1 = iADX(SymboleCible, PERIOD_M1, 14);
   hATR_M1 = iATR(SymboleCible, PERIOD_M1, 14);
   hOBV_M1 = iOBV(SymboleCible, PERIOD_M1, VOLUME_TICK);
   hSuperTrend_M15 = iCustom(SymboleCible, PERIOD_M15, "::Indicators\\ScalpOr\\SuperTrend.ex5",
                              ATRPeriode_SuperTrend, Multiplicateur_SuperTrend);

   if(hRSI_M1 == INVALID_HANDLE || hADX_M1 == INVALID_HANDLE || hATR_M1 == INVALID_HANDLE ||
      hOBV_M1 == INVALID_HANDLE || hSuperTrend_M15 == INVALID_HANDLE)
   {
      Print("ERREUR : creation d'un handle d'indicateur a echoue, arret du script");
      return;
   }

   int totalBarres = Bars(SymboleCible, PERIOD_M1);

   //--- Attente que les indicateurs aient fini de calculer sur l'historique
   AttendreCalculIndicateur(hRSI_M1, totalBarres);
   AttendreCalculIndicateur(hADX_M1, totalBarres);
   AttendreCalculIndicateur(hATR_M1, totalBarres);
   AttendreCalculIndicateur(hOBV_M1, totalBarres);
   AttendreCalculIndicateur(hSuperTrend_M15, Bars(SymboleCible, PERIOD_M15));

   double atrTerciles[2];
   CalculerTercilesATR(atrTerciles);
   g_atrTerciles[0] = atrTerciles[0];
   g_atrTerciles[1] = atrTerciles[1];

   int index = totalBarres - 1; // on part du plus ancien vers le plus recent

   int barresTraitees = 0;

   while(index > PlafondBarresGardeFou)
   {
      datetime tBarre = iTime(SymboleCible, PERIOD_M1, index);
      if(tBarre < DateDebut) { index--; continue; }
      if(tBarre > DateFin) break;

      int regime = EncoderRegime(tBarre);
      int bucketRSI, bucketADX, bucketATR, bucketOBV;
      EncoderEtatFin(index, atrTerciles, bucketRSI, bucketADX, bucketATR, bucketOBV);

      int resultat = MesurerMouvementFutur(index, MultipleATR_MouvementFav, PlafondBarresGardeFou);
      // resultat : 1 = favorable, -1 = defavorable, 0 = exclu (plafond atteint)

      EnregistrerOccurrence(regime, bucketRSI, bucketADX, bucketATR, bucketOBV, resultat);

      barresTraitees++;
      index--;
   }

   Print("Barres traitees : ", barresTraitees, " | Etats distincts : ", NbEtats);

   VerifierTailleEchantillon();
   CalculerPoidsIndicateurs();
   ExporterPoids();
   ExporterMarginales();
   ExporterCalibration();

   //--- Liberation des handles (bonne pratique MQL5 en fin de script)
   IndicatorRelease(hRSI_M1);
   IndicatorRelease(hADX_M1);
   IndicatorRelease(hATR_M1);
   IndicatorRelease(hOBV_M1);
   IndicatorRelease(hSuperTrend_M15);

   Print("=== MoteurProbabiliste : calibration terminee ===");
}

//+------------------------------------------------------------------+
//| Regime grossier M15 (SuperTrend) - contexte uniquement            |
//+------------------------------------------------------------------+
int EncoderRegime(datetime tBarre)
{
   // CORRECTION : utilise desormais le vrai SuperTrend (iCustom, handle
   // hSuperTrend_M15) au lieu du placeholder EMA50. CEncodageEtat::Regime()
   // n'a pas change -- la ligne SuperTrend se comporte comme l'EMA (sous
   // le prix en tendance haussiere, au-dessus en baissiere), donc la
   // comparaison close > ligne / close < ligne reste valide telle quelle.
   int shift = iBarShift(SymboleCible, PERIOD_M15, tBarre, true);
   if(shift < 1) shift = 1; // force la derniere bougie M15 deja cloturee

   double closeM15      = iClose(SymboleCible, PERIOD_M15, shift);
   double superTrendM15 = ObtenirValeurIndicateur(hSuperTrend_M15, shift);

   return CEncodageEtat::Regime(closeM15, superTrendM15);
}

//+------------------------------------------------------------------+
//| Etat fin M1 : RSI, ADX, ATR (tercile), OBV                        |
//+------------------------------------------------------------------+
void EncoderEtatFin(int shift, const double &atrTerciles[], int &bucketRSI, int &bucketADX, int &bucketATR, int &bucketOBV)
{
   bucketRSI = CEncodageEtat::BucketRSI(ObtenirValeurIndicateur(hRSI_M1, shift));
   bucketADX = CEncodageEtat::BucketADX(ObtenirValeurIndicateur(hADX_M1, shift));
   bucketATR = CEncodageEtat::BucketATR(ObtenirValeurIndicateur(hATR_M1, shift), atrTerciles[0], atrTerciles[1]);
   bucketOBV = CEncodageEtat::BucketOBV(ObtenirValeurIndicateur(hOBV_M1, shift), ObtenirValeurIndicateur(hOBV_M1, shift + 10));
}

//+------------------------------------------------------------------+
//| Mesure du mouvement futur relatif a l'ATR                          |
//| Retourne : 1 = favorable atteint, -1 = defavorable atteint,        |
//|            0 = exclu (plafond de barres atteint sans issue)        |
//+------------------------------------------------------------------+
int MesurerMouvementFutur(int shiftDepart, double multipleATR, int plafondBarres)
{
   double atrRef  = ObtenirValeurIndicateur(hATR_M1, shiftDepart);
   double prixRef = iClose(SymboleCible, PERIOD_M1, shiftDepart);
   double seuil   = atrRef * multipleATR;

   for(int i = 1; i <= plafondBarres; i++)
   {
      int shiftCourant = shiftDepart - i; // on avance vers le present (shift decroissant)
      if(shiftCourant < 0) break;

      double haut = iHigh(SymboleCible, PERIOD_M1, shiftCourant);
      double bas  = iLow(SymboleCible, PERIOD_M1, shiftCourant);

      bool toucheHaut = (haut - prixRef >= seuil);
      bool toucheBas  = (prixRef - bas  >= seuil);

      // Bougie ambigue (touche les DEUX seuils) : on ne peut pas savoir
      // lequel a ete atteint en premier sans donnees intra-barre. La
      // compter comme "hausse" (ancien comportement, haut teste avant bas)
      // introduisait un biais haussier systematique -> on l'exclut plutot.
      if(toucheHaut && toucheBas) return 0;

      if(toucheHaut) return 1;  // le prix monte de 1 ATR en premier
      if(toucheBas)  return -1; // le prix descend de 1 ATR en premier
   }
   return 0; // plafond atteint sans issue -> exclu de l'echantillon
}

//+------------------------------------------------------------------+
//| Accumulation dans la table d'etats                                 |
//+------------------------------------------------------------------+
void EnregistrerOccurrence(int regime, int bRSI, int bADX, int bATR, int bOBV, int resultat)
{
   int idx = TrouverOuCreerEtat(regime, bRSI, bADX, bATR, bOBV);
   if(idx < 0) return;

   EtatsTable[idx].occurrences++;
   if(resultat == 1)      EtatsTable[idx].favorables++;
   else if(resultat == -1) EtatsTable[idx].defavorables++;
   else                     EtatsTable[idx].exclusions++;
}

int TrouverOuCreerEtat(int regime, int bRSI, int bADX, int bATR, int bOBV)
{
   for(int i = 0; i < NbEtats; i++)
   {
      if(EtatsTable[i].regime == regime && EtatsTable[i].bucketRSI == bRSI &&
         EtatsTable[i].bucketADX == bADX && EtatsTable[i].bucketATR == bATR &&
         EtatsTable[i].bucketOBV == bOBV)
         return i;
   }
   if(NbEtats >= MAX_ETATS) { Print("ERREUR : MAX_ETATS depasse"); return -1; }

   EtatsTable[NbEtats].regime = regime;
   EtatsTable[NbEtats].bucketRSI = bRSI;
   EtatsTable[NbEtats].bucketADX = bADX;
   EtatsTable[NbEtats].bucketATR = bATR;
   EtatsTable[NbEtats].bucketOBV = bOBV;
   NbEtats++;
   return NbEtats - 1;
}

//+------------------------------------------------------------------+
//| Terciles ATR sur la periode (pour bucketiser la volatilite)        |
//+------------------------------------------------------------------+
void CalculerTercilesATR(double &terciles[])
{
   // Premier passage dedie : on collecte l'ATR de chaque barre M1 de la
   // periode avant la boucle principale, pour calculer les terciles reels
   // plutot que des seuils devines.
   //
   // Filtrage par timestamp direct (pas iBarShift, qui echoue si DateDebut/
   // DateFin tombe un week-end/jour ferie ou hors historique charge) :
   // on borne juste l'iteration a la fenetre demandee, en bornant aussi
   // l'allocation a tout l'historique M1 disponible.
   int totalBarres = Bars(SymboleCible, PERIOD_M1);
   if(totalBarres <= 0)
   {
      Print("ERREUR : aucun historique M1 disponible pour ", SymboleCible);
      terciles[0] = 0.0;
      terciles[1] = 0.0;
      return;
   }

   double valeursATR[];
   ArrayResize(valeursATR, totalBarres);
   int nbValeurs = 0;

   for(int index = totalBarres - 1; index >= 0; index--)
   {
      datetime tBarre = iTime(SymboleCible, PERIOD_M1, index);
      if(tBarre <= 0) continue;          // barre invalide
      if(tBarre < DateDebut) continue;   // avant la fenetre : on saute
      if(tBarre > DateFin) break;        // apres la fenetre : on arrete (barres triees)

      double atr = ObtenirValeurIndicateur(hATR_M1, index);
      if(atr <= 0) continue; // barre sans historique ATR suffisant, on l'ignore

      valeursATR[nbValeurs] = atr;
      nbValeurs++;
   }

   if(nbValeurs == 0)
   {
      Print("ERREUR : aucune valeur ATR collectee sur la periode ",
            TimeToString(DateDebut, TIME_DATE), " -> ", TimeToString(DateFin, TIME_DATE),
            " (verifiez que l'historique M1 couvre bien cette plage)");
      terciles[0] = 0.0;
      terciles[1] = 0.0;
      return;
   }

   ArrayResize(valeursATR, nbValeurs);
   ArraySort(valeursATR); // tri croissant, necessaire pour les percentiles

   int indexP33 = (int)MathFloor(nbValeurs * 0.33);
   int indexP66 = (int)MathFloor(nbValeurs * 0.66);

   terciles[0] = valeursATR[indexP33]; // seuil bas/moyen (33e percentile)
   terciles[1] = valeursATR[indexP66]; // seuil moyen/eleve (66e percentile)

   Print("Terciles ATR calcules sur ", nbValeurs, " barres : bas/moyen=",
         DoubleToString(terciles[0], 5), " | moyen/eleve=", DoubleToString(terciles[1], 5));
}

//+------------------------------------------------------------------+
//| Filtre les etats sous-echantillonnes (seuil minimal)               |
//+------------------------------------------------------------------+
void VerifierTailleEchantillon()
{
   int nbExclus = 0;
   for(int i = 0; i < NbEtats; i++)
   {
      if(EtatsTable[i].occurrences < SeuilMinEchantillon)
         nbExclus++;
   }
   Print("Etats sous le seuil minimal (", SeuilMinEchantillon, " occurrences) : ", nbExclus, " / ", NbEtats);
}

//+------------------------------------------------------------------+
//| Extrait la valeur de bucket d'un indicateur donne pour un etat     |
//+------------------------------------------------------------------+
int ObtenirBucket(int idxEtat, ENUM_TYPE_INDICATEUR type)
{
   switch(type)
   {
      case TYPE_RSI: return EtatsTable[idxEtat].bucketRSI;
      case TYPE_ADX: return EtatsTable[idxEtat].bucketADX;
      case TYPE_ATR: return EtatsTable[idxEtat].bucketATR;
      case TYPE_OBV: return EtatsTable[idxEtat].bucketOBV;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Pouvoir predictif isole d'un indicateur : ecart moyen (pondere     |
//| par occurrences) entre la probabilite par bucket et la            |
//| probabilite de base (marginale, tous etats confondus). Remplit     |
//| aussi margOut[] avec la probabilite marginale de chaque bucket,    |
//| necessaire a CFiltres (qui a besoin d'un bucket isole, pas d'un    |
//| etat complet comme IQM).                                           |
//+------------------------------------------------------------------+
double CalculerPoidsUnIndicateur(ENUM_TYPE_INDICATEUR type, int nbBuckets, double probaBase, double &margOut[])
{
   double sommeDeviationPonderee = 0.0;
   long   sommeOccurrences = 0;

   ArrayResize(margOut, nbBuckets);
   ArrayInitialize(margOut, -1.0); // -1 = bucket jamais rencontre / sous-echantillonne

   for(int b = 0; b < nbBuckets; b++)
   {
      long occB = 0, favB = 0, defavB = 0;

      for(int i = 0; i < NbEtats; i++)
      {
         if(EtatsTable[i].occurrences < SeuilMinEchantillon) continue; // meme filtre que l'export
         if(ObtenirBucket(i, type) != b) continue;

         occB   += EtatsTable[i].occurrences;
         favB   += EtatsTable[i].favorables;
         defavB += EtatsTable[i].defavorables;
      }

      long baseB = favB + defavB;
      if(baseB == 0) continue; // aucun etat exploitable pour ce bucket

      double probaB = (double)favB / baseB;
      margOut[b] = probaB;

      double deviation = MathAbs(probaB - probaBase);

      sommeDeviationPonderee += deviation * occB;
      sommeOccurrences += occB;
   }

   if(sommeOccurrences == 0) return 0.0;
   return sommeDeviationPonderee / sommeOccurrences;
}

//+------------------------------------------------------------------+
//| Pouvoir predictif isole de chaque indicateur (pour le poids IQM)   |
//+------------------------------------------------------------------+
void CalculerPoidsIndicateurs()
{
   //--- Probabilite de base : tous etats filtres confondus (marginale)
   long favTotal = 0, defavTotal = 0;
   for(int i = 0; i < NbEtats; i++)
   {
      if(EtatsTable[i].occurrences < SeuilMinEchantillon) continue;
      favTotal   += EtatsTable[i].favorables;
      defavTotal += EtatsTable[i].defavorables;
   }

   if(favTotal + defavTotal == 0)
   {
      Print("ERREUR : aucun etat exploitable pour calculer la probabilite de base");
      ArrayInitialize(PoidsIndicateurs, 0.0);
      return;
   }

   g_probaBase = (double)favTotal / (favTotal + defavTotal);
   Print("Probabilite de base (marginale) : ", DoubleToString(g_probaBase, 4));

   //--- Pouvoir predictif brut par indicateur + probabilites marginales par bucket
   double brutRSI = CalculerPoidsUnIndicateur(TYPE_RSI, 3, g_probaBase, MargRSI);
   double brutADX = CalculerPoidsUnIndicateur(TYPE_ADX, 2, g_probaBase, MargADX);
   double brutATR = CalculerPoidsUnIndicateur(TYPE_ATR, 3, g_probaBase, MargATR);
   double brutOBV = CalculerPoidsUnIndicateur(TYPE_OBV, 2, g_probaBase, MargOBV);
   CalculerMarginaleRegime(MargRegime); // hors ponderation IQM, utile a Filtres uniquement

   double sommeBrut = brutRSI + brutADX + brutATR + brutOBV;

   //--- Normalisation : les 4 poids somment a 1, consommables directement
   //    par IQM.CalculerScore() comme ponderation d'une somme
   if(sommeBrut > 0)
   {
      PoidsIndicateurs[TYPE_RSI] = brutRSI / sommeBrut;
      PoidsIndicateurs[TYPE_ADX] = brutADX / sommeBrut;
      PoidsIndicateurs[TYPE_ATR] = brutATR / sommeBrut;
      PoidsIndicateurs[TYPE_OBV] = brutOBV / sommeBrut;
   }
   else
   {
      Print("ATTENTION : aucun indicateur n'a de pouvoir predictif mesurable, poids egaux par defaut");
      ArrayInitialize(PoidsIndicateurs, 0.25);
   }

   Print("Poids normalises -> RSI=", DoubleToString(PoidsIndicateurs[TYPE_RSI], 4),
         " ADX=", DoubleToString(PoidsIndicateurs[TYPE_ADX], 4),
         " ATR=", DoubleToString(PoidsIndicateurs[TYPE_ATR], 4),
         " OBV=", DoubleToString(PoidsIndicateurs[TYPE_OBV], 4));
}

//+------------------------------------------------------------------+
//| Export des poids par indicateur (granularite differente des       |
//| etats -> fichier separe, lu par IQM en complement de              |
//| calibration.csv)                                                   |
//+------------------------------------------------------------------+
void ExporterPoids()
{
   int handle = FileOpen("ScalpOr\\poids_indicateurs.csv", FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ';');
   if(handle == INVALID_HANDLE) { Print("ERREUR ouverture poids_indicateurs.csv"); return; }

   FileWrite(handle, "cle", "valeur");
   FileWrite(handle, "RSI", DoubleToString(PoidsIndicateurs[TYPE_RSI], 4));
   FileWrite(handle, "ADX", DoubleToString(PoidsIndicateurs[TYPE_ADX], 4));
   FileWrite(handle, "ATR", DoubleToString(PoidsIndicateurs[TYPE_ATR], 4));
   FileWrite(handle, "OBV", DoubleToString(PoidsIndicateurs[TYPE_OBV], 4));
   // Terciles ATR : indispensables pour qu'IQM bucketise l'ATR en temps reel
   // avec exactement les memes seuils qu'utilises a la calibration
   FileWrite(handle, "ATR_Tercile_Bas", DoubleToString(g_atrTerciles[0], 5));
   FileWrite(handle, "ATR_Tercile_Haut", DoubleToString(g_atrTerciles[1], 5));
   FileWrite(handle, "ProbaBase", DoubleToString(g_probaBase, 4));

   FileClose(handle);
   Print("poids_indicateurs.csv exporte (poids + terciles ATR)");
}

//+------------------------------------------------------------------+
//| Export des probabilites marginales par bucket isole, pour         |
//| CFiltres (TendanceOK/MomentumOK/VolumeOK/VolatiliteOK)             |
//+------------------------------------------------------------------+
void ExporterMarginales()
{
   int handle = FileOpen("ScalpOr\\seuils_filtres.csv", FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ';');
   if(handle == INVALID_HANDLE) { Print("ERREUR ouverture seuils_filtres.csv"); return; }

   FileWrite(handle, "indicateur", "bucket", "probabilite");

   for(int b = 0; b < 3; b++) FileWrite(handle, "RSI", b, DoubleToString(MargRSI[b], 4));
   for(int b = 0; b < 2; b++) FileWrite(handle, "ADX", b, DoubleToString(MargADX[b], 4));
   for(int b = 0; b < 3; b++) FileWrite(handle, "ATR", b, DoubleToString(MargATR[b], 4));
   for(int b = 0; b < 2; b++) FileWrite(handle, "OBV", b, DoubleToString(MargOBV[b], 4));
   for(int b = 0; b < 3; b++) FileWrite(handle, "REGIME", b - 1, DoubleToString(MargRegime[b], 4));

   FileClose(handle);
   Print("seuils_filtres.csv exporte");
}

//+------------------------------------------------------------------+
//| Export de la table de calibration en CSV                          |
//+------------------------------------------------------------------+
void ExporterCalibration()
{
   int handle = FileOpen("ScalpOr\\calibration.csv", FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ';');
   if(handle == INVALID_HANDLE) { Print("ERREUR ouverture calibration.csv"); return; }

   FileWrite(handle, "regime", "bucketRSI", "bucketADX", "bucketATR", "bucketOBV",
                      "occurrences", "favorables", "defavorables", "exclusions", "probabilite");

   for(int i = 0; i < NbEtats; i++)
   {
      if(EtatsTable[i].occurrences < SeuilMinEchantillon) continue; // filtre le sous-echantillonnage

      long base = EtatsTable[i].favorables + EtatsTable[i].defavorables;
      double proba = (base > 0) ? (double)EtatsTable[i].favorables / base : 0.0;

      FileWrite(handle,
         EtatsTable[i].regime, EtatsTable[i].bucketRSI, EtatsTable[i].bucketADX,
         EtatsTable[i].bucketATR, EtatsTable[i].bucketOBV,
         EtatsTable[i].occurrences, EtatsTable[i].favorables,
         EtatsTable[i].defavorables, EtatsTable[i].exclusions,
         DoubleToString(proba, 4));
   }

   FileClose(handle);
   Print("calibration.csv exporte (", NbEtats, " etats avant filtrage)");
}
