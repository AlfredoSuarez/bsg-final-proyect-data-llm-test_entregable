{
  "Comment": "RAG Pipeline Orchestrator — Acme Co Marketplace B2B PyME. Coordina ETL (Glue) -> Chunking + Embeddings (Lambda) -> Indexer (ECS Fargate) -> Version registration (DynamoDB).",
  "StartAt": "InitializeRun",
  "TimeoutSeconds": 5400,
  "States": {

    "InitializeRun": {
      "Type": "Pass",
      "Comment": "Genera un version_id estable basado en el Execution name de Step Functions y captura el inicio del run para metricas.",
      "Parameters": {
        "version_id.$": "States.Format('run-{}', $$.Execution.Name)",
        "started_at.$": "$$.Execution.StartTime",
        "execution_arn.$": "$$.Execution.Id"
      },
      "Next": "StartGlueETL"
    },

    "StartGlueETL": {
      "Type": "Task",
      "Resource": "arn:aws:states:::glue:startJobRun.sync",
      "Comment": "Invoca el Glue Job de ETL en modo sincrono — bloquea hasta completar.",
      "Parameters": {
        "JobName": "${glue_job_name}",
        "Arguments": {
          "--input_bucket": "${raw_bucket}",
          "--output_bucket": "${clean_bucket}",
          "--input_prefix": "raw/",
          "--output_prefix": "clean/",
          "--version_id.$": "$.version_id"
        }
      },
      "ResultPath": "$.glue_result",
      "Retry": [
        {
          "ErrorEquals": ["Glue.ConcurrentRunsExceededException", "Glue.ResourceNumberLimitExceededException"],
          "IntervalSeconds": 60,
          "MaxAttempts": 3,
          "BackoffRate": 2.0
        },
        {
          "ErrorEquals": ["States.TaskFailed"],
          "IntervalSeconds": 30,
          "MaxAttempts": 2,
          "BackoffRate": 2.0
        }
      ],
      "Catch": [
        {
          "ErrorEquals": ["States.ALL"],
          "ResultPath": "$.error",
          "Next": "NotifyFailure"
        }
      ],
      "Next": "ListCleanParquetFiles"
    },

    "ListCleanParquetFiles": {
      "Type": "Task",
      "Resource": "arn:aws:states:::aws-sdk:s3:listObjectsV2",
      "Comment": "Lista los Parquet emitidos por Glue para distribuir el chunking en paralelo.",
      "Parameters": {
        "Bucket": "${clean_bucket}",
        "Prefix": "clean/"
      },
      "ResultPath": "$.parquet_list",
      "Retry": [
        {
          "ErrorEquals": ["States.TaskFailed"],
          "IntervalSeconds": 5,
          "MaxAttempts": 3,
          "BackoffRate": 2.0
        }
      ],
      "Catch": [
        {
          "ErrorEquals": ["States.ALL"],
          "ResultPath": "$.error",
          "Next": "NotifyFailure"
        }
      ],
      "Next": "ChunkAllParquetsInParallel"
    },

    "ChunkAllParquetsInParallel": {
      "Type": "Map",
      "Comment": "Map state: invoca la Lambda de chunking + embeddings por cada Parquet, con concurrencia controlada para no exceder cuotas de Bedrock.",
      "ItemsPath": "$.parquet_list.Contents",
      "MaxConcurrency": 5,
      "ItemSelector": {
        "key.$": "$$.Map.Item.Value.Key",
        "version_id.$": "$.version_id"
      },
      "ItemProcessor": {
        "ProcessorConfig": {
          "Mode": "INLINE"
        },
        "StartAt": "InvokeChunkingLambda",
        "States": {
          "InvokeChunkingLambda": {
            "Type": "Task",
            "Resource": "arn:aws:states:::lambda:invoke",
            "Parameters": {
              "FunctionName": "${lambda_chunking_function_name}",
              "Payload": {
                "Records": [
                  {
                    "s3": {
                      "bucket": { "name": "${clean_bucket}" },
                      "object": { "key.$": "$.key" }
                    }
                  }
                ],
                "version_id.$": "$.version_id"
              }
            },
            "Retry": [
              {
                "ErrorEquals": ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"],
                "IntervalSeconds": 2,
                "MaxAttempts": 4,
                "BackoffRate": 2.0,
                "JitterStrategy": "FULL"
              },
              {
                "ErrorEquals": ["Lambda.Unknown", "States.TaskFailed"],
                "IntervalSeconds": 10,
                "MaxAttempts": 2,
                "BackoffRate": 2.0
              }
            ],
            "End": true
          }
        }
      },
      "ResultPath": "$.chunking_results",
      "Catch": [
        {
          "ErrorEquals": ["States.ALL"],
          "ResultPath": "$.error",
          "Next": "NotifyFailure"
        }
      ],
      "Next": "RunIndexerTask"
    },

    "RunIndexerTask": {
      "Type": "Task",
      "Resource": "arn:aws:states:::ecs:runTask.sync",
      "Comment": "Corre el indexer ECS Fargate sincronicamente — bloquea hasta que el container salga.",
      "Parameters": {
        "Cluster": "${ecs_cluster_arn}",
        "TaskDefinition": "${ecs_task_definition_arn}",
        "LaunchType": "FARGATE",
        "NetworkConfiguration": {
          "AwsvpcConfiguration": {
            "Subnets": ${private_subnets_json},
            "SecurityGroups": ["${ecs_security_group_id}"],
            "AssignPublicIp": "DISABLED"
          }
        },
        "Overrides": {
          "ContainerOverrides": [
            {
              "Name": "indexer",
              "Environment": [
                { "Name": "VERSION_ID", "Value.$": "$.version_id" },
                { "Name": "GIT_COMMIT", "Value": "step-functions" }
              ]
            }
          ]
        }
      },
      "ResultPath": "$.indexer_result",
      "Retry": [
        {
          "ErrorEquals": ["ECS.AmazonECSException", "States.TaskFailed"],
          "IntervalSeconds": 30,
          "MaxAttempts": 2,
          "BackoffRate": 2.0
        }
      ],
      "Catch": [
        {
          "ErrorEquals": ["States.ALL"],
          "ResultPath": "$.error",
          "Next": "NotifyFailure"
        }
      ],
      "Next": "PublishCustomMetric"
    },

    "PublishCustomMetric": {
      "Type": "Task",
      "Resource": "arn:aws:states:::aws-sdk:cloudwatch:putMetricData",
      "Comment": "Emite metrica custom RAGPipeline/PipelineRunsSucceeded = 1 con dimension Environment.",
      "Parameters": {
        "Namespace": "RAGPipeline",
        "MetricData": [
          {
            "MetricName": "PipelineRunsSucceeded",
            "Value": 1,
            "Unit": "Count",
            "Dimensions": [
              { "Name": "Environment", "Value": "${environment}" }
            ]
          }
        ]
      },
      "ResultPath": "$.metric_result",
      "Retry": [
        {
          "ErrorEquals": ["States.TaskFailed"],
          "IntervalSeconds": 5,
          "MaxAttempts": 2
        }
      ],
      "Next": "NotifySuccess"
    },

    "NotifySuccess": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sns:publish",
      "Comment": "Notifica al topic de exito con el resumen del run.",
      "Parameters": {
        "TopicArn": "${sns_success_topic_arn}",
        "Subject.$": "States.Format('[RAG Pipeline OK] {}', $.version_id)",
        "Message.$": "States.Format('Run {} completado. Indexer status: {}. Started: {}.', $.version_id, $.indexer_result.LastStatus, $.started_at)"
      },
      "ResultPath": null,
      "End": true
    },

    "NotifyFailure": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sns:publish",
      "Comment": "Notifica al topic de fallo con el error capturado.",
      "Parameters": {
        "TopicArn": "${sns_failure_topic_arn}",
        "Subject.$": "States.Format('[RAG Pipeline FAIL] {}', $.version_id)",
        "Message.$": "States.JsonToString($)"
      },
      "ResultPath": null,
      "Next": "PublishFailureMetric"
    },

    "PublishFailureMetric": {
      "Type": "Task",
      "Resource": "arn:aws:states:::aws-sdk:cloudwatch:putMetricData",
      "Parameters": {
        "Namespace": "RAGPipeline",
        "MetricData": [
          {
            "MetricName": "PipelineRunsFailed",
            "Value": 1,
            "Unit": "Count",
            "Dimensions": [
              { "Name": "Environment", "Value": "${environment}" }
            ]
          }
        ]
      },
      "ResultPath": null,
      "Next": "FailState"
    },

    "FailState": {
      "Type": "Fail",
      "Comment": "Termina el run en estado FAILED para que CloudWatch detecte la falla."
    }
  }
}
