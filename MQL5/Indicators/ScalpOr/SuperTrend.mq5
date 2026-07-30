//+------------------------------------------------------------------+
//| SuperTrend.mq5                                                    |
//| Indicateur SuperTrend classique (bandes ATR + multiplicateur),    |
//| pour remplacer le placeholder EMA50 utilise jusqu'ici par         |
//| CEncodageEtat::Regime (via CIndicateurs.MA_M15).                  |
//|                                                                    |
//| Buffer 0 (SuperTrendBuffer) : la ligne SuperTrend elle-meme.       |
//|   En tendance haussiere, la ligne est SOUS le prix (support) ;     |
//|   en tendance baissiere, elle est AU-DESSUS (resistance). Cette    |
//|   propriete est EXACTEMENT celle utilisee par                     |
//|   CEncodageEtat::Regime(close, ligne) -- close > ligne = haussier,|
//|   close < ligne = baissier -- donc aucun changement necessaire    |
//|   cote Regime(), seule la source de la valeur change (EMA50 ->    |
//|   SuperTrend).                                                    |
//|                                                                    |
//| Buffer 1 (TrendBuffer) : direction, +1 haussier / -1 baissier,     |
//| expose au cas ou vous en auriez besoin ailleurs (non utilise par   |
//| Regime() qui se contente de comparer close a la ligne).           |
//+------------------------------------------------------------------+
#property strict
#property indicator_chart_window
#property indicator_buffers 4
#property indicator_plots   1
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDodgerBlue
#property indicator_width1  2

input int    InpATRPeriod    = 10;   // Periode ATR
input double InpMultiplicateur = 3.0; // Multiplicateur des bandes

double SuperTrendBuffer[];
double TrendBuffer[];        // +1 / -1, non trace
double UpperBandBuffer[];    // intermediaire, non trace
double LowerBandBuffer[];    // intermediaire, non trace

int hATR;

int OnInit()
{
   SetIndexBuffer(0, SuperTrendBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, TrendBuffer,      INDICATOR_CALCULATIONS);
   SetIndexBuffer(2, UpperBandBuffer,  INDICATOR_CALCULATIONS);
   SetIndexBuffer(3, LowerBandBuffer,  INDICATOR_CALCULATIONS);

   ArraySetAsSeries(SuperTrendBuffer, false);
   ArraySetAsSeries(TrendBuffer, false);
   ArraySetAsSeries(UpperBandBuffer, false);
   ArraySetAsSeries(LowerBandBuffer, false);

   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, InpATRPeriod);
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   hATR = iATR(_Symbol, _Period, InpATRPeriod);
   if(hATR == INVALID_HANDLE)
   {
      Print("SuperTrend : echec de creation du handle ATR");
      return INIT_FAILED;
   }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
}

int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                const double &open[], const double &high[], const double &low[], const double &close[],
                const long &tick_volume[], const long &volume[], const int &spread[])
{
   if(rates_total <= InpATRPeriod) return 0;

   double atr[];
   ArraySetAsSeries(atr, false);
   if(CopyBuffer(hATR, 0, 0, rates_total, atr) <= 0) return 0;

   int start = (prev_calculated > InpATRPeriod) ? prev_calculated - 1 : InpATRPeriod;

   for(int i = start; i < rates_total; i++)
   {
      double milieu = (high[i] + low[i]) / 2.0;
      double bandeHauteBase = milieu + InpMultiplicateur * atr[i];
      double bandeBasseBase = milieu - InpMultiplicateur * atr[i];

      if(i == InpATRPeriod)
      {
         UpperBandBuffer[i] = bandeHauteBase;
         LowerBandBuffer[i] = bandeBasseBase;
         TrendBuffer[i] = (close[i] > bandeHauteBase) ? 1 : -1;
         SuperTrendBuffer[i] = (TrendBuffer[i] == 1) ? LowerBandBuffer[i] : UpperBandBuffer[i];
         continue;
      }

      // Bande haute finale : ne descend que si le prix precedent etait sous elle
      UpperBandBuffer[i] = (bandeHauteBase < UpperBandBuffer[i-1] || close[i-1] > UpperBandBuffer[i-1])
                            ? bandeHauteBase : UpperBandBuffer[i-1];

      // Bande basse finale : ne monte que si le prix precedent etait au-dessus d'elle
      LowerBandBuffer[i] = (bandeBasseBase > LowerBandBuffer[i-1] || close[i-1] < LowerBandBuffer[i-1])
                            ? bandeBasseBase : LowerBandBuffer[i-1];

      // Bascule de tendance : cassure d'une bande finale
      if(TrendBuffer[i-1] == 1 && close[i] < LowerBandBuffer[i])
         TrendBuffer[i] = -1;
      else if(TrendBuffer[i-1] == -1 && close[i] > UpperBandBuffer[i])
         TrendBuffer[i] = 1;
      else
         TrendBuffer[i] = TrendBuffer[i-1];

      SuperTrendBuffer[i] = (TrendBuffer[i] == 1) ? LowerBandBuffer[i] : UpperBandBuffer[i];
   }

   return rates_total;
}
