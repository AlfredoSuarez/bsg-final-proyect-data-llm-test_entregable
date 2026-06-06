# KPIs para evaluar un agente LLM

Este documento reúne los principales KPIs usados para evaluar agentes LLM en operación, incluyendo definición, fórmula matemática, utilidad y área funcional que cubre. Las métricas más usadas en producción se agrupan en calidad de respuesta, alucinación, rendimiento, costos, seguridad y experiencia de usuario.[cite:18][cite:19][cite:22][cite:24]

## Criterio de formato para Notion y Confluence

Para mejorar compatibilidad visual, las fórmulas se presentan en formato de texto matemático simple, evitando notación que suele renderizarse mal al pegar tablas desde Markdown. En lugar de depender de renderizado LaTeX embebido dentro de celdas, se usa una notación lineal clara y portable.[cite:22][cite:24]

## Tabla de KPIs

| KPI | Fórmula matemática | Para qué sirve | Área que cubre |
|---|---|---|---|
| Task Success Rate | TSR = tareas resueltas correctamente / tareas totales | Mide el porcentaje de casos en que el agente completa correctamente el objetivo del usuario o del proceso.[cite:19][cite:22][cite:24] | Calidad / Outcome de negocio |
| Answer Accuracy | Accuracy = respuestas correctas / respuestas evaluadas | Evalúa la precisión de las respuestas frente a un ground truth, dataset etiquetado o evaluación con LLM-as-a-judge.[cite:16][cite:17][cite:22][cite:24] | Calidad de respuesta |
| Precision | Precision = TP / (TP + FP) | En tareas de clasificación o extracción, indica qué proporción de predicciones positivas fue correcta.[cite:17][cite:22][cite:24] | Calidad de respuesta |
| Recall | Recall = TP / (TP + FN) | Mide qué proporción de casos positivos reales fue detectada por el sistema.[cite:17][cite:22][cite:24] | Calidad de respuesta |
| F1 Score | F1 = 2 x (Precision x Recall) / (Precision + Recall) | Balancea precisión y cobertura en una sola métrica, útil cuando ambas importan al mismo tiempo.[cite:17][cite:22][cite:24] | Calidad de respuesta |
| Faithfulness / Grounding | Faithfulness = respuestas fieles al contexto / respuestas totales | Mide si la respuesta está soportada por el contexto, documentos recuperados o base de conocimiento autorizada.[cite:20][cite:22][cite:24] | Alucinación / Veracidad |
| Hallucination Rate | HR = respuestas con alucinación / respuestas totales | Cuantifica la proporción de respuestas con contenido falso, inventado o no soportado.[cite:20][cite:22][cite:24] | Alucinación / Riesgo |
| Retrieval Recall@k | Recall@k = queries con al menos 1 documento relevante en top-k / queries totales | Permite saber si el sistema RAG recupera evidencia útil para contestar bien.[cite:20][cite:22][cite:24] | Recuperación / RAG |
| Retrieval Precision@k | Precision@k = documentos relevantes en top-k / k | Mide cuánto ruido o señal hay en el contexto recuperado para el modelo.[cite:20][cite:22][cite:24] | Recuperación / RAG |
| Tool Call Accuracy | TCA = llamadas correctas de tool / llamadas totales de tool | Evalúa si el agente elige la herramienta correcta y la invoca con parámetros válidos.[cite:19][cite:22][cite:24] | Orquestación / Tools |
| Schema Validity Rate | SVR = salidas válidas contra schema / salidas totales | Asegura que los outputs estructurados cumplan con el formato esperado, por ejemplo JSON válido.[cite:22][cite:24] | Integración / Robustez técnica |
| Turns-to-Success | TtS = suma de turnos en casos exitosos / casos exitosos | Mide cuántos intercambios necesita el agente para completar una tarea, lo que refleja fricción conversacional.[cite:18][cite:22][cite:24] | UX conversacional |
| Escalation Rate | ER = casos escalados a humano / casos totales | Indica qué proporción de casos no puede resolver el agente sin apoyo humano.[cite:19][cite:22][cite:24] | Operación / Eficiencia |
| End-to-End Latency p50 | Latency p50 = percentil 50 del tiempo total de respuesta | Refleja el tiempo de respuesta típico percibido por el usuario.[cite:18][cite:19][cite:22][cite:24] | Rendimiento / UX |
| End-to-End Latency p95 | Latency p95 = percentil 95 del tiempo total de respuesta | Ayuda a detectar colas, outliers y degradaciones severas del servicio.[cite:18][cite:19][cite:22][cite:24] | Rendimiento / Confiabilidad |
| Time to First Token | TTFT = tiempo del primer token - tiempo del request | Mide qué tan rápido el usuario empieza a ver respuesta en experiencias con streaming.[cite:18][cite:22][cite:24] | UX / Velocidad percibida |
| Cost per Successful Task | CPST = (costo de tokens + costo de tools + otros costos) / tareas exitosas | Permite evaluar la eficiencia económica del agente por caso resuelto con éxito.[cite:18][cite:19][cite:22][cite:24] | Costos / Eficiencia |
| Tokens per Interaction | TPI = suma de tokens de entrada y salida / interacciones totales | Sirve para optimizar prompts, contexto y gasto de inferencia.[cite:18][cite:19][cite:24] | Costos / Diseño de prompts |
| Error Rate | Error Rate = interacciones con error / interacciones totales | Mide fallos técnicos como timeouts, errores de parsing, errores de API o fallas de tools.[cite:18][cite:19][cite:22] | Confiabilidad técnica |
| Policy Violation Rate | PVR = respuestas con violación de política / respuestas totales | Controla incumplimientos de seguridad, compliance o reglas de uso aceptable.[cite:18][cite:22][cite:24] | Seguridad / Cumplimiento |
| Toxicity Rate | Toxicity Rate = respuestas tóxicas / respuestas totales | Cuantifica la proporción de salidas con lenguaje ofensivo, agresivo o inapropiado.[cite:18][cite:24][cite:29] | Seguridad / Riesgo reputacional |
| PII Leakage Incidents | PII Incidents = número de respuestas con datos personales expuestos en el periodo | Cuenta incidentes de fuga de datos sensibles o personales.[cite:18][cite:22][cite:24][cite:29] | Seguridad / Privacidad |
| CSAT | CSAT = suma de calificaciones de satisfacción / número de respuestas de encuesta | Mide la satisfacción promedio reportada por usuarios después de la interacción.[cite:18][cite:19][cite:24] | UX / Satisfacción |
| User Feedback Rate | Feedback Rate = interacciones con feedback / interacciones totales | Indica la cobertura de retroalimentación explícita disponible para mejora continua.[cite:18][cite:24] | UX / Mejora continua |

## Recomendación de uso

Para operación empresarial, normalmente conviene monitorear un set mínimo formado por Task Success Rate, Hallucination Rate, Tool Call Accuracy, Latencia p95, Cost per Successful Task y Policy Violation Rate, porque juntas cubren outcome, riesgo, desempeño y costo.[cite:18][cite:19][cite:22][cite:24] En agentes con RAG, también conviene agregar Retrieval Recall@k y Faithfulness para separar problemas del retrieval frente a problemas del modelo generativo.[cite:20][cite:22][cite:24]

## Sugerencia de estructura en Confluence o Notion

La tabla puede complementarse con columnas operativas como `Owner`, `Fuente de datos`, `Frecuencia de medición`, `Meta`, `Umbral de alerta` y `Acción correctiva`, lo que facilita convertirla en catálogo oficial de métricas o scorecard de operación.[cite:18][cite:19][cite:24]
