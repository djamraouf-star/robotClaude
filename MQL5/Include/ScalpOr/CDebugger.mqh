//+------------------------------------------------------------------+
//| CDebugger.mqh                                                    |
//| Traceur d'exécution pour le débogage hors ligne                  |
//+------------------------------------------------------------------+
#property strict

enum ENUM_DEBUG_LEVEL
{
   DEBUG_LEVEL_NONE  = 0,
   DEBUG_LEVEL_ERROR = 1,
   DEBUG_LEVEL_WARN  = 2,
   DEBUG_LEVEL_INFO  = 3,
   DEBUG_LEVEL_TRACE = 4
};

class CDebugger
{
private:
   string           m_dossier;
   string           m_nomFichier;
   ENUM_DEBUG_LEVEL m_level;
   int              m_fileHandle;

   string CheminLog() const { return m_dossier + "\\" + m_nomFichier; }

public:
   CDebugger(string dossier = "ScalpOr", string nomFichier = "debug_trace.log", ENUM_DEBUG_LEVEL level = DEBUG_LEVEL_TRACE)
   {
      m_dossier = dossier;
      m_nomFichier = nomFichier;
      m_level = level;
      m_fileHandle = INVALID_HANDLE;
      
      if(m_level > DEBUG_LEVEL_NONE)
      {
         m_fileHandle = FileOpen(CheminLog(), FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
         if(m_fileHandle != INVALID_HANDLE)
         {
            FileWrite(m_fileHandle, "=== INITIALISATION DEBUGGER: ", TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), " ===");
         }
      }
   }

   ~CDebugger()
   {
      if(m_fileHandle != INVALID_HANDLE)
      {
         FileWrite(m_fileHandle, "=== FERMETURE DEBUGGER: ", TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), " ===");
         FileClose(m_fileHandle);
      }
   }

   void Log(ENUM_DEBUG_LEVEL msgLevel, string context, string message)
   {
      if(m_level < msgLevel || m_fileHandle == INVALID_HANDLE) return;

      string sLevel = "";
      switch(msgLevel)
      {
         case DEBUG_LEVEL_ERROR: sLevel = "[ERROR]"; break;
         case DEBUG_LEVEL_WARN:  sLevel = "[WARN] "; break;
         case DEBUG_LEVEL_INFO:  sLevel = "[INFO] "; break;
         case DEBUG_LEVEL_TRACE: sLevel = "[TRACE]"; break;
      }

      string fullMessage = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + " " + sLevel + " [" + context + "] " + message;
      
      FileWrite(m_fileHandle, fullMessage);
      FileFlush(m_fileHandle);
   }

   void Trace(string context, string message) { Log(DEBUG_LEVEL_TRACE, context, message); }
   void Info(string context, string message)  { Log(DEBUG_LEVEL_INFO, context, message); }
   void Warn(string context, string message)  { Log(DEBUG_LEVEL_WARN, context, message); }
   void Error(string context, string message) { Log(DEBUG_LEVEL_ERROR, context, message); }
};
