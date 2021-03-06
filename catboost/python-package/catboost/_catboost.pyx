# distutils: language = c++
# coding: utf-8
# cython: wraparound=False

import six
from six import iteritems, string_types, PY3
from six.moves import range
from json import dumps, loads, JSONEncoder
from copy import deepcopy
from collections import Sequence, defaultdict

import numpy as np
cimport numpy as np

np.import_array()

cimport cython
from cython.operator cimport dereference

from libc.math cimport isnan
from libc.stdint cimport uint32_t, uint64_t
from libcpp cimport bool as bool_t
from libcpp.map cimport map as cmap
from libcpp.vector cimport vector
from libcpp.pair cimport pair

from util.generic.string cimport TString
from util.generic.vector cimport TVector
from util.generic.maybe cimport TMaybe
from util.generic.hash cimport THashMap
from util.system.types cimport ui8, ui32, ui64
from util.generic.ptr cimport THolder


class _NumpyAwareEncoder(JSONEncoder):
    bool_types = (np.bool_)
    tolist_types = (np.ndarray,)
    def default(self, obj):
        if np.issubdtype(type(obj), np.integer):
            return int(obj)
        if np.issubdtype(type(obj), np.floating):
            return float(obj)
        if isinstance(obj, self.bool_types):
            return bool(obj)
        if isinstance(obj, self.tolist_types):
            return obj.tolist()
        return JSONEncoder.default(self, obj)


class CatboostError(Exception):
    pass

cdef public object PyCatboostExceptionType = <object>CatboostError


cdef extern from "catboost/python-package/catboost/helpers.h":
    cdef void ProcessException()
    cdef void SetPythonInterruptHandler() nogil
    cdef void ResetPythonInterruptHandler() nogil

# TODO(akhropov): Add necessary methods to util's def
cdef extern from "util/generic/strbuf.h":
    cdef cppclass TStringBuf:
        TStringBuf() except +
        TStringBuf(const char*) except +
        TStringBuf(const char*, size_t) except +
        char* Data()
        size_t Size()

cdef extern from "catboost/libs/logging/logging.h":
    cdef void SetCustomLoggingFunction(void(*func)(const char*, size_t len) except * with gil, void(*func)(const char*, size_t len) except * with gil)
    cdef void RestoreOriginalLogger()


cdef extern from "catboost/libs/cat_feature/cat_feature.h":
    cdef int CalcCatFeatureHash(TStringBuf feature) except +ProcessException
    cdef float ConvertCatFeatureHashToFloat(int hashVal) except +ProcessException


cdef extern from "catboost/libs/data_types/pair.h":
    cdef cppclass TPair:
        ui32 WinnerId
        ui32 LoserId
        float Weight
        TPair(ui32 winnerId, ui32 loserId, float weight) nogil except +ProcessException

cdef extern from "catboost/libs/data_types/groupid.h":
    ctypedef ui64 TGroupId
    ctypedef ui32 TSubgroupId
    cdef TGroupId CalcGroupIdFor(const TStringBuf& token) except +ProcessException
    cdef TSubgroupId CalcSubgroupIdFor(const TStringBuf& token) except +ProcessException

cdef extern from "catboost/libs/data/quantized_features.h":
    cdef cppclass TAllFeatures:
        TVector[TVector[ui8]] FloatHistograms
        TVector[TVector[int]] CatFeaturesRemapped
        TVector[TVector[int]] OneHotValues
        TVector[bool_t] IsOneHot

    cdef cppclass TPoolMetaInfo:
        ui32 FeatureCount
        ui32 BaselineCount
        bool_t HasGroupId
        bool_t HasGroupWeight
        bool_t HasSubgroupIds
        bool_t HasWeights
        bool_t HasTimestamp
        # ColumnsInfo is not here because it is not used for now

    cdef cppclass TPool:
        TDocumentStorage Docs
        TVector[int] CatFeatures
        TVector[TString] FeatureId
        THashMap[int, TString] CatFeaturesHashToString
        TVector[TPair] Pairs
        TPoolMetaInfo MetaInfo
        bint operator==(TPool)
        void SetCatFeatureHashWithBackMapUpdate(
            size_t factorIdx,
            size_t docIdx,
            TStringBuf catFeatureString
        ) except +ProcessException

    cdef cppclass TClearablePoolPtrs:
        TPool* Learn
        bool_t AllowClearLearn
        const TVector[const TPool*] Test
        bool_t AllowClearTest

    cdef THolder[TPool] SlicePool(const TPool& pool, const TVector[size_t]& indices) except +ProcessException


cdef extern from "catboost/libs/data_util/path_with_scheme.h" namespace "NCB":
    cdef cppclass TPathWithScheme:
        TString Scheme
        TString Path
        TPathWithScheme() except +ProcessException
        TPathWithScheme(const TStringBuf& pathWithScheme, const TStringBuf& defaultScheme) except +ProcessException
        bool_t Inited() except +ProcessException

cdef extern from "catboost/libs/data_util/line_data_reader.h" namespace "NCB":
    cdef cppclass TDsvFormatOptions:
        bool_t HasHeader
        char Delimiter

cdef extern from "catboost/libs/options/load_options.h" namespace "NCatboostOptions":
    cdef cppclass TDsvPoolFormatParams:
        TDsvFormatOptions Format
        TPathWithScheme CdFilePath


cdef extern from "catboost/libs/data/load_data.h" namespace "NCB":
    cdef void ReadPool(
        const TPathWithScheme& poolPath,
        const TPathWithScheme& pairsFilePath,
        const TPathWithScheme& groupWeightsFilePath,
        const TDsvPoolFormatParams& dsvPoolFormatParams,
        const TVector[int]& ignoredFeatures,
        int threadCount,
        bool_t verbose,
        TPool* pool
    ) nogil except +ProcessException

cdef extern from "catboost/libs/algo/hessian.h":
    cdef cppclass THessianInfo:
        TVector[double] Data

cdef extern from "catboost/libs/model/model.h":
    cdef cppclass TCatFeature:
        int FeatureIndex
        int FlatFeatureIndex
        TString FeatureId

    cdef cppclass TFloatFeature:
        bool_t HasNans
        int FeatureIndex
        int FlatFeatureIndex
        TVector[float] Borders
        TString FeatureId

    cdef cppclass TObliviousTrees:
        int ApproxDimension
        TVector[TVector[double]] LeafWeights
        TVector[TCatFeature] CatFeatures
        TVector[TFloatFeature] FloatFeatures
        void Truncate(size_t begin, size_t end) except +ProcessException

    cdef cppclass TFullModel:
        TObliviousTrees ObliviousTrees

        THashMap[TString, TString] ModelInfo
        void Swap(TFullModel& other) except +ProcessException
        size_t GetTreeCount() nogil except +ProcessException

    cdef cppclass EModelType:
        pass

    cdef EModelType EModelType_Catboost "EModelType::CatboostBinary"
    cdef EModelType EModelType_CoreML "EModelType::AppleCoreML"
    cdef EModelType EModelType_CPP "EModelType::CPP"
    cdef EModelType EModelType_Python "EModelType::Python"
    cdef EModelType EModelType_JSON "EModelType::json"

    cdef void ExportModel(
        const TFullModel& model,
        const TString& modelFile,
        const EModelType format,
        const TString& userParametersJson,
        bool_t addFileFormatExtension,
        const TVector[TString]* featureId,
        const THashMap[int, TString]* catFeaturesHashToString
    ) except +ProcessException

    cdef void OutputModel(const TFullModel& model, const TString& modelFile) except +ProcessException
    cdef TFullModel ReadModel(const TString& modelFile, EModelType format) nogil except +ProcessException
    cdef TString SerializeModel(const TFullModel& model) except +ProcessException
    cdef TFullModel DeserializeModel(const TString& serializeModelString) nogil except +ProcessException
    cdef TVector[TString] GetModelUsedFeaturesNames(const TFullModel& model) except +ProcessException

cdef extern from "catboost/libs/data/pool.h":
    cdef cppclass TDocumentStorage:
        TVector[TVector[float]] Factors
        TVector[TVector[double]] Baseline
        TVector[TString] Label
        TVector[float] Target
        TVector[float] Weight
        TVector[uint64_t] QueryId
        TVector[uint32_t] SubgroupId
        int GetBaselineDimension() except +ProcessException const
        int GetEffectiveFactorCount() except +ProcessException const
        size_t GetDocCount() except +ProcessException const
        void Swap(TDocumentStorage& other) except +ProcessException
        void AssignDoc(int destinationIdx, const TDocumentStorage& sourceDocs, int sourceIdx) except +ProcessException
        void Resize(int docCount, int featureCount, int approxDim, bool_t hasQueryId, bool_t hasSubgroupId) except +ProcessException
        void Clear() except +ProcessException

    cdef cppclass TPoolMetaInfo:
        bool_t HasGroupWeight

    cdef cppclass TPool:
        TDocumentStorage Docs
        TAllFeatures QuantizedFeatures
        TVector[TFloatFeature] FloatFeatures
        TVector[int] CatFeatures
        TVector[TString] FeatureId
        THashMap[int, TString] CatFeaturesHashToString
        TVector[TPair] Pairs
        TPoolMetaInfo MetaInfo
        bint operator==(TPool)
        void SetCatFeatureHashWithBackMapUpdate(
            size_t factorIdx,
            size_t docIdx,
            TStringBuf catFeatureString
        ) except +ProcessException

    cdef THolder[TPool] SlicePool(const TPool& pool, const TVector[size_t]& indices) except +ProcessException


cdef extern from "library/json/writer/json_value.h" namespace "NJson":
    cdef cppclass TJsonValue:
        pass

cdef extern from "library/containers/2d_array/2d_array.h":
    cdef cppclass TArray2D[T]:
        T* operator[] (size_t index) const

cdef extern from "util/system/info.h" namespace "NSystemInfo":
    cdef size_t CachedNumberOfCpus() except +ProcessException

cdef extern from "catboost/libs/metrics/metric_holder.h":
    cdef cppclass TMetricHolder:
        TVector[double] Stats

        void Add(TMetricHolder& other) except +ProcessException

cdef extern from "catboost/libs/metrics/metric.h":
    cdef cppclass IMetric:
        TString GetDescription() const;
        bool_t IsAdditiveMetric() const;

cdef extern from "catboost/libs/metrics/metric.h":
    cdef bool_t IsMaxOptimal(const IMetric& metric);

cdef extern from "catboost/libs/metrics/ders_holder.h":
    cdef cppclass TDers:
        double Der1
        double Der2

cdef extern from "catboost/libs/options/enums.h":
    cdef cppclass EPredictionType:
        pass

    cdef EPredictionType EPredictionType_Class "EPredictionType::Class"
    cdef EPredictionType EPredictionType_Probability "EPredictionType::Probability"
    cdef EPredictionType EPredictionType_RawFormulaVal "EPredictionType::RawFormulaVal"

cdef extern from "catboost/libs/options/enum_helpers.h":
    cdef bool_t IsClassificationLoss(const TString& lossFunction) nogil except +ProcessException

cdef extern from "catboost/libs/metrics/metric.h":
    cdef cppclass TCustomMetricDescriptor:
        void* CustomData

        TMetricHolder (*EvalFunc)(
            const TVector[TVector[double]]& approx,
            const TVector[float]& target,
            const TVector[float]& weight,
            int begin, int end, void* customData
        ) except * with gil

        TString (*GetDescriptionFunc)(void *customData) except * with gil
        bool_t (*IsMaxOptimalFunc)(void *customData) except * with gil
        double (*GetFinalErrorFunc)(const TMetricHolder& error, void *customData) except * with gil

    cdef cppclass TCustomObjectiveDescriptor:
        void* CustomData

        void (*CalcDersRange)(
            int count,
            const double* approxes,
            const float* targets,
            const float* weights,
            TDers* ders,
            void* customData
        ) except * with gil

        void (*CalcDersMulti)(
            const TVector[double]& approx,
            float target,
            float weight,
            TVector[double]* ders,
            THessianInfo* der2,
            void* customData
        ) except * with gil

cdef extern from "catboost/libs/options/cross_validation_params.h":
    cdef cppclass TCrossValidationParams:
        ui32 FoldCount
        bool_t Inverted
        int PartitionRandSeed
        bool_t Shuffle
        bool_t Stratified
        int EvalPeriod

cdef extern from "catboost/libs/options/check_train_options.h":
    cdef void CheckFitParams(
        const TJsonValue& tree,
        const TCustomObjectiveDescriptor* objectiveDescriptor,
        const TCustomMetricDescriptor* evalMetricDescriptor
    ) nogil except +ProcessException

cdef extern from "catboost/libs/options/json_helper.h":
    cdef TJsonValue ReadTJsonValue(const TString& paramsJson) nogil except +ProcessException

cdef extern from "catboost/libs/train_lib/train_model.h":
    cdef void TrainModel(
        const TJsonValue& params,
        const TMaybe[TCustomObjectiveDescriptor]& objectiveDescriptor,
        const TMaybe[TCustomMetricDescriptor]& evalMetricDescriptor,
        const TClearablePoolPtrs& clearablePoolPtrs,
        const TString& outputModelPath,
        TFullModel* model,
        const TVector[TEvalResult*]& testApproxes
    ) nogil except +ProcessException

cdef extern from "catboost/libs/train_lib/cross_validation.h":
    cdef cppclass TCVResult:
        TString Metric
        TVector[double] AverageTrain
        TVector[double] StdDevTrain
        TVector[double] AverageTest
        TVector[double] StdDevTest

    cdef void CrossValidate(
        const TJsonValue& jsonParams,
        const TMaybe[TCustomObjectiveDescriptor]& objectiveDescriptor,
        const TMaybe[TCustomMetricDescriptor]& evalMetricDescriptor,
        TPool& pool,
        const TCrossValidationParams& cvParams,
        TVector[TCVResult]* results
    ) nogil except +ProcessException

cdef extern from "catboost/libs/algo/apply.h":
    cdef TVector[double] ApplyModel(
        const TFullModel& model,
        const TPool& pool,
        bool_t verbose,
        const EPredictionType predictionType,
        int begin,
        int end,
        int threadCount
    ) nogil except +ProcessException

    cdef TVector[TVector[double]] ApplyModelMulti(
        const TFullModel& calcer,
        const TPool& pool,
        bool_t verbose,
        const EPredictionType predictionType,
        int begin,
        int end,
        int threadCount
    ) nogil except +ProcessException

cdef extern from "catboost/libs/algo/helpers.h":
    cdef void ConfigureMalloc() nogil except *

cdef extern from "catboost/libs/algo/roc_curve.h":
    cdef cppclass TRocPoint:
        double Boundary
        double FalseNegativeRate
        double FalsePositiveRate

        TRocPoint() nogil

        TRocPoint(double boundary, double FalseNegativeRate, double FalsePositiveRate) nogil

    cdef cppclass TRocCurve:
        TRocCurve() nogil

        TRocCurve(
            const TFullModel& model,
            const TVector[TPool]& pool,
            int threadCount
        ) nogil

        TRocCurve(const TVector[TRocPoint]& points) nogil

        double SelectDecisionBoundaryByFalsePositiveRate(
            double falsePositiveRate
        ) nogil except +ProcessException

        double SelectDecisionBoundaryByFalseNegativeRate(
            double falseNegativeRate
        ) nogil except +ProcessException

        double SelectDecisionBoundaryByIntersection() nogil except +ProcessException

        TVector[TRocPoint] GetCurvePoints() nogil except +ProcessException

        void Output(const TString& outputPath)

cdef extern from "catboost/libs/eval_result/eval_helpers.h":
    cdef TVector[TVector[double]] PrepareEval(
        const EPredictionType predictionType,
        const TVector[TVector[double]]& approx,
        int threadCount
    ) nogil except +ProcessException

    cdef TVector[TVector[double]] PrepareEvalForInternalApprox(
        const EPredictionType predictionType,
        const TFullModel& model,
        const TVector[TVector[double]]& approx,
        int threadCount
    ) nogil except +ProcessException

    cdef TVector[TString] ConvertTargetToExternalName(
        const TVector[float]& target,
        const TFullModel& model
    ) nogil except +ProcessException

cdef extern from "catboost/libs/eval_result/eval_result.h" namespace "NCB":
    cdef cppclass TEvalResult:
        TVector[TVector[TVector[double]]] GetRawValuesRef() except * with gil
        void ClearRawValues() except * with gil

cdef extern from "catboost/libs/init/init_reg.h" namespace "NCB":
    cdef void LibraryInit() nogil except *

cdef extern from "catboost/libs/fstr/calc_fstr.h":
    cdef TVector[TVector[double]] GetFeatureImportances(
        const TString& type,
        const TFullModel& model,
        const TPool* pool,
        int threadCount,
        int logPeriod
    ) nogil except +ProcessException

    cdef TVector[TVector[TVector[double]]] GetFeatureImportancesMulti(
        const TString& type,
        const TFullModel& model,
        const TPool* pool,
        int threadCount,
        int logPeriod
    ) nogil except +ProcessException

    TVector[TString] GetMaybeGeneratedModelFeatureIds(
        const TFullModel& model,
        const TPool* pool
    ) nogil except +ProcessException


cdef extern from "catboost/libs/documents_importance/docs_importance.h":
    cdef cppclass TDStrResult:
        TVector[TVector[uint32_t]] Indices
        TVector[TVector[double]] Scores
    cdef TDStrResult GetDocumentImportances(
        const TFullModel& model,
        const TPool& trainPool,
        const TPool& testPool,
        const TString& dstrType,
        int topSize,
        const TString& updateMethod,
        const TString& importanceValuesSign,
        int threadCount
    ) nogil except +ProcessException

cdef extern from "catboost/libs/helpers/wx_test.h":
    cdef cppclass TWxTestResult:
        double WPlus
        double WMinus
        double PValue
    cdef TWxTestResult WxTest(const TVector[double]& baseline, const TVector[double]& test) nogil except +ProcessException

cdef extern from "util/string/cast.h":
    cdef double StrToD(const char* b, char** se)

cdef float _FLOAT_NAN = float('nan')

cdef extern from "catboost/libs/data/doc_pool_data_provider.h" namespace "NCB":
    int IsNanValue(const TStringBuf& s)

cdef inline float _FloatOrNanFromString(char* s) except *:
    cdef char* stop = NULL
    cdef double parsed = StrToD(s, &stop)
    cdef float res
    if len(s) == 0:
        res = _FLOAT_NAN
    elif stop == s + len(s):
        res = float(parsed)
    elif IsNanValue(s):
        res = _FLOAT_NAN
    else:
        raise TypeError("Cannot convert '{}' to float".format(str(s)))
    return res

cdef extern from "catboost/libs/gpu_config/interface/get_gpu_device_count.h" namespace "NCB":
    cdef int GetGpuDeviceCount()

cdef extern from "catboost/python-package/catboost/helpers.h":
    cdef TVector[TVector[double]] EvalMetrics(
        const TFullModel& model,
        const TPool& pool,
        const TVector[TString]& metricsDescription,
        int begin,
        int end,
        int evalPeriod,
        int threadCount,
        const TString& resultDir,
        const TString& tmpDir
    ) nogil except +ProcessException

    cdef TVector[TString] GetMetricNames(
        const TFullModel& model,
        const TVector[TString]& metricsDescription
    ) nogil except +ProcessException

    cdef TVector[double] EvalMetricsForUtils(
        const TVector[float]& label,
        const TVector[TVector[double]]& approx,
        const TString& metricName,
        const TVector[float]& weight,
        const TVector[TGroupId]& groupId,
        int threadCount
    ) nogil except +ProcessException

    cdef cppclass TMetricsPlotCalcerPythonWrapper:
        TMetricsPlotCalcerPythonWrapper(TVector[TString]& metrics, TFullModel& model, int ntree_start, int ntree_end,
                                        int eval_period, int thread_count, TString& tmpDir,
                                        bool_t flag) except +ProcessException
        TVector[const IMetric*] GetMetricRawPtrs() const
        TVector[TVector[double]] ComputeScores()
        void AddPool(const TPool& pool)


cdef inline float _FloatOrNan(object obj) except *:
    try:
        return float(obj)
    except:
        pass

    cdef float res
    if obj is None:
        res = _FLOAT_NAN
    elif isinstance(obj, string_types + (np.string_,)):
        res = _FloatOrNanFromString(to_binary_str(obj))
    else:
        raise TypeError("Cannot convert obj {} to float".format(str(obj)))
    return res

cdef TString _MetricGetDescription(void* customData) except * with gil:
    cdef metricObject = <object>customData
    name = metricObject.__class__.__name__
    if PY3:
        name = name.encode()
    return TString(<const char*>name)

cdef bool_t _MetricIsMaxOptimal(void* customData) except * with gil:
    cdef metricObject = <object>customData
    return metricObject.is_max_optimal()

cdef double _MetricGetFinalError(const TMetricHolder& error, void *customData) except * with gil:
    # TODO(nikitxskv): use error.Stats for custom metrics.
    cdef metricObject = <object>customData
    return metricObject.get_final_error(error.Stats[0], error.Stats[1])

cdef class _FloatArrayWrapper:
    cdef const float* _arr
    cdef int _count

    @staticmethod
    cdef create(const float* arr, int count):
        wrapper = _FloatArrayWrapper()
        wrapper._arr = arr
        wrapper._count = count
        return wrapper

    def __getitem__(self, key):
        if key >= self._count:
            raise IndexError()

        return self._arr[key]

    def __len__(self):
        return self._count

# Cython does not have generics so using small copy-paste here and below
cdef class _DoubleArrayWrapper:
    cdef const double* _arr
    cdef int _count

    @staticmethod
    cdef create(const double* arr, int count):
        wrapper = _DoubleArrayWrapper()
        wrapper._arr = arr
        wrapper._count = count
        return wrapper

    def __getitem__(self, key):
        if key >= self._count:
            raise IndexError()

        return self._arr[key]

    def __len__(self):
        return self._count

cdef TMetricHolder _MetricEval(
    const TVector[TVector[double]]& approx,
    const TVector[float]& target,
    const TVector[float]& weight,
    int begin,
    int end,
    void* customData
) except * with gil:
    cdef metricObject = <object>customData
    cdef TMetricHolder holder
    holder.Stats.resize(2)

    approxes = [_DoubleArrayWrapper.create(approx[i].data() + begin, end - begin) for i in xrange(approx.size())]
    targets = _FloatArrayWrapper.create(target.data() + begin, end - begin)

    if weight.size() == 0:
        weights = None
    else:
        weights = _FloatArrayWrapper.create(weight.data() + begin, end - begin)

    error, weight_ = metricObject.evaluate(approxes, targets, weights)

    holder.Stats[0] = error
    holder.Stats[1] = weight_
    return holder

cdef void _ObjectiveCalcDersRange(
    int count,
    const double* approxes,
    const float* targets,
    const float* weights,
    TDers* ders,
    void* customData
) except * with gil:
    cdef objectiveObject = <object>(customData)

    approx = _DoubleArrayWrapper.create(approxes, count)
    target = _FloatArrayWrapper.create(targets, count)

    if weights:
        weight = _FloatArrayWrapper.create(weights, count)
    else:
        weight = None

    result = objectiveObject.calc_ders_range(approx, target, weight)
    index = 0
    for der1, der2 in result:
        ders[index].Der1 = der1
        ders[index].Der2 = der2
        index += 1

cdef void _ObjectiveCalcDersMulti(
    const TVector[double]& approx,
    float target,
    float weight,
    TVector[double]* ders,
    THessianInfo* der2,
    void* customData
) except * with gil:
    cdef objectiveObject = <object>(customData)

    approxes = _DoubleArrayWrapper.create(approx.data(), approx.size())

    ders_vector, second_ders_matrix = objectiveObject.calc_ders_multi(approxes, target, weight)
    for index, der in enumerate(ders_vector):
        dereference(ders)[index] = der

    index = 0
    for indY, line in enumerate(second_ders_matrix):
        for num in line[indY:]:
            dereference(der2).Data[index] = num
            index += 1

cdef TCustomMetricDescriptor _BuildCustomMetricDescriptor(object metricObject):
    cdef TCustomMetricDescriptor descriptor
    descriptor.CustomData = <void*>metricObject
    descriptor.EvalFunc = &_MetricEval
    descriptor.GetDescriptionFunc = &_MetricGetDescription
    descriptor.IsMaxOptimalFunc = &_MetricIsMaxOptimal
    descriptor.GetFinalErrorFunc = &_MetricGetFinalError
    return descriptor

cdef TCustomObjectiveDescriptor _BuildCustomObjectiveDescriptor(object objectiveObject):
    cdef TCustomObjectiveDescriptor descriptor
    descriptor.CustomData = <void*>objectiveObject
    descriptor.CalcDersRange = &_ObjectiveCalcDersRange
    descriptor.CalcDersMulti = &_ObjectiveCalcDersMulti
    return descriptor

cdef class PyPredictionType:
    cdef EPredictionType predictionType
    def __init__(self, prediction_type):
        if prediction_type == 'Class':
            self.predictionType = EPredictionType_Class
        elif prediction_type == 'Probability':
            self.predictionType = EPredictionType_Probability
        else:
            self.predictionType = EPredictionType_RawFormulaVal

cdef class PyModelType:
    cdef EModelType modelType
    def __init__(self, model_type):
        if model_type == 'coreml':
            self.modelType = EModelType_CoreML
        elif model_type == 'cpp':
            self.modelType = EModelType_CPP
        elif model_type == 'python':
            self.modelType = EModelType_Python
        elif model_type == 'json':
            self.modelType = EModelType_JSON
        elif model_type == 'cbm' or model_type == 'catboost':
            self.modelType = EModelType_Catboost
        else:
            raise CatboostError("Unknown model type {}.".format(model_type))

cdef class _PreprocessParams:
    cdef TJsonValue tree
    cdef TMaybe[TCustomObjectiveDescriptor] customObjectiveDescriptor
    cdef TMaybe[TCustomMetricDescriptor] customMetricDescriptor
    def __init__(self, dict params):
        eval_metric = params.get("eval_metric")
        objective = params.get("loss_function")

        is_custom_eval_metric = eval_metric is not None and not isinstance(eval_metric, string_types)
        is_custom_objective = objective is not None and not isinstance(objective, string_types)

        devices = params.get('devices')
        if devices is not None and isinstance(devices, list):
            params['devices'] = ':'.join(map(str, devices))

        params_to_json = params

        if is_custom_objective or is_custom_eval_metric:
            keys_to_replace = set()
            if is_custom_objective:
                keys_to_replace.add("loss_function")
            if is_custom_eval_metric:
                keys_to_replace.add("eval_metric")

            params_to_json = {}

            for k, v in params.iteritems():
                if k in keys_to_replace:
                    continue
                params_to_json[k] = deepcopy(v)

            for k in keys_to_replace:
                params_to_json[k] = "Custom"

        dumps_params = dumps(params_to_json, cls=_NumpyAwareEncoder)

        if params_to_json.get("loss_function") == "Custom":
            self.customObjectiveDescriptor = _BuildCustomObjectiveDescriptor(params["loss_function"])
        if params_to_json.get("eval_metric") == "Custom":
            self.customMetricDescriptor = _BuildCustomMetricDescriptor(params["eval_metric"])

        dumps_params = to_binary_str(dumps_params)
        self.tree = ReadTJsonValue(TString(<const char*>dumps_params))

cdef to_binary_str(string):
    if PY3:
        return string.encode()
    return string

cdef to_native_str(binary):
    if PY3:
        return binary.decode()
    return binary


cdef inline object get_id_object_bytes_string_representation(
    object id_object,
    TStringBuf* bytes_string_buf_representation
):
    """
        returns python object, holding bytes_string_buf_representation memory,
        keep until bytes_string_buf_representation no longer needed

        Internal CatboostError is typically catched up the calling stack to provide more detailed error
        description.
    """
    if not isinstance(id_object, string_types):
        if isnan(id_object) or int(id_object) != id_object:
            raise CatboostError("bad object for id: {}".format(id_object))
        id_object = str(int(id_object))
    bytes_string_representation = to_binary_str(id_object)

    # for some reason Cython does not allow assignment to dereferenced pointer, so use this trick instead
    bytes_string_buf_representation[0] = TStringBuf(
        <char*>bytes_string_representation,
        len(bytes_string_representation)
    )
    return bytes_string_representation


cdef UpdateThreadCount(thread_count):
    if thread_count == -1:
        thread_count = CachedNumberOfCpus()
    if thread_count < 1:
        raise CatboostError("Invalid thread_count value={} : must be > 0".format(thread_count))
    return thread_count


class FeaturesData(object):
    """
       class to store features data in optimized form to pass to Pool constructor

       stores the following:
          num_feature_data  - np.ndarray of (object_count x num_feature_count) with dtype=np.float32 or None
          cat_feature_data  - np.ndarray of (object_count x cat_feature_count) with dtype=object,
                              elements must have 'bytes' type, containing utf-8 encoded strings
          num_feature_names - sequence of (str or bytes) or None
          cat_feature_names - sequence of (str or bytes) or None

          if feature names are not specified they are initialized to empty strings.
    """

    def __init__(
        self,
        num_feature_data=None,
        cat_feature_data=None,
        num_feature_names=None,
        cat_feature_names=None
    ):
        if (num_feature_data is None) and (cat_feature_data is None):
            raise CatboostError('at least one of num_feature_data, cat_feature_data params must be non-None')

        # list to pass 'by reference'
        all_feature_count_ref = [0]
        self._check_and_set_part('num', num_feature_data, np.float32, num_feature_names, all_feature_count_ref)
        self._check_and_set_part('cat', cat_feature_data, object, cat_feature_names, all_feature_count_ref)

        if all_feature_count_ref[0] == 0:
            raise CatboostError('both num_feature_data and cat_feature_data contain 0 features')

        if (num_feature_data is not None) and (cat_feature_data is not None):
            if num_feature_data.shape[0] != cat_feature_data.shape[0]:
                raise CatboostError(
                    'object_counts in num_feature_data ({}) and in cat_feature_data ({}) are different'.format(
                        len(num_feature_data), len(cat_feature_data)
                    )
                )

    def _check_and_set_part(
        self,
        part_name,
        feature_data,
        supported_element_type,
        feature_names,
        all_feature_count_ref # 1-element list to emulate pass-by-reference
    ):
        if (feature_names is not None) and (feature_data is None):
            raise CatboostError(
                '{}_feature_names specified with not specified {}_feature_data'.format(
                    part_name, part_name
                )
            )
        if feature_data is not None:
            if not isinstance(feature_data, np.ndarray):
                raise CatboostError(
                    'only np.ndarray type is supported for {}_feature_data'.format(part_name)
                )
            if len(feature_data.shape) != 2:
                raise CatboostError(
                    '{}_feature_data must be 2D numpy.ndarray, it has shape {} instead'.format(
                        part_name, feature_data.shape
                    )
                )
            if feature_data.dtype != supported_element_type:
                raise CatboostError(
                    '{}_feature_data element type must be {}, found {} instead'.format(
                        part_name, supported_element_type, feature_data.dtype
                    )
                )
            if feature_names is not None:
                for i, name in enumerate(feature_names):
                    if type(name) != str:
                        raise CatboostError(
                            'type of {}_feature_names[{}]: expected str, found {}'
                        )
                if feature_data.shape[1] != len(feature_names):
                    raise CatboostError(
                        (
                            'number of features in {}_feature_data (={}) is different from '
                            ' len({}_feature_names) (={})'.format(
                                part_name, feature_data.shape[1], part_name, len(feature_names)
                            )
                        )
                    )
            all_feature_count_ref[0] += feature_data.shape[1]

        setattr(self, part_name + '_feature_data', feature_data)
        setattr(
            self,
            part_name + '_feature_names',
            (
                feature_names if feature_names is not None
                else (['']*feature_data.shape[1] if feature_data is not None else [])
            )
        )

    def get_object_count(self):
        if self.num_feature_data is not None:
            return self.num_feature_data.shape[0]
        if self.cat_feature_data is not None:
            return self.cat_feature_data.shape[0]

    def get_num_feature_count(self):
        return self.num_feature_data.shape[1] if self.num_feature_data is not None else 0

    def get_cat_feature_count(self):
        return self.cat_feature_data.shape[1] if self.cat_feature_data is not None else 0

    def get_feature_count(self):
        return self.get_num_feature_count() + self.get_cat_feature_count()

    def get_feature_names(self):
        """
            empty strings are returned for features for which no names data was specified
        """
        return self.num_feature_names + self.cat_feature_names


cdef class _PoolBase:
    cdef TPool* __pool
    cdef bool_t has_label_

    def __cinit__(self):
        self.__pool = new TPool()
        self.has_label_ = False

    def __dealloc__(self):
        del self.__pool

    def __deepcopy__(self, _):
        raise CatboostError('Can\'t deepcopy _PoolBase object')

    def __eq__(self, _PoolBase other):
        return dereference(self.__pool) == dereference(other.__pool)

    cpdef _read_pool(self, pool_file, cd_file, pairs_file, delimiter, bool_t has_header, int thread_count):
        pool_file = to_binary_str(pool_file)
        cdef TPathWithScheme pool_file_path
        pool_file_path = TPathWithScheme(TStringBuf(<char*>pool_file), TStringBuf(<char*>'dsv'))

        pairs_file = to_binary_str(pairs_file)
        cdef TPathWithScheme pairs_file_path
        if len(pairs_file):
            pairs_file_path = TPathWithScheme(TStringBuf(<char*>pairs_file), TStringBuf(<char*>'dsv'))

        cdef TDsvPoolFormatParams dsvPoolFormatParams
        dsvPoolFormatParams.Format.HasHeader = has_header
        dsvPoolFormatParams.Format.Delimiter = ord(delimiter)
        cd_file = to_binary_str(cd_file)
        if len(cd_file):
            dsvPoolFormatParams.CdFilePath = TPathWithScheme(TStringBuf(<char*>cd_file), TStringBuf(<char*>'dsv'))

        thread_count = UpdateThreadCount(thread_count);

        cdef TVector[int] emptyIntVec

        ReadPool(
            pool_file_path,
            pairs_file_path,
            TPathWithScheme(),
            dsvPoolFormatParams,
            emptyIntVec,
            thread_count,
            False,
            self.__pool
        )

        if len([target for target in self.__pool.Docs.Target]) > 1:
            self.has_label_ = True

    cpdef _init_pool(self, data, label, cat_features, pairs, weight, group_id, group_weight, subgroup_id, pairs_weight, baseline, feature_names):
        if group_weight is not None and weight is not None:
            raise CatboostError('Pool must have either weight or group_weight.')

        if cat_features is not None:
            self._init_cat_features(cat_features)
        self._set_data_and_feature_names(data, feature_names)
        num_class = 2
        if label is not None:
            self._set_label(label)
            num_class = len(set(list(label)))
            self.has_label_ = True
        if pairs is not None:
            self._set_pairs(pairs)
        if baseline is not None:
            self._set_baseline(baseline)
        if weight is not None:
            self._set_weight(weight)
        if group_id is not None:
            self._set_group_id(group_id)
        if group_weight is not None:
            self._set_group_weight(group_weight)
        if subgroup_id is not None:
            self._set_subgroup_id(subgroup_id)
        if pairs_weight is not None:
            self._set_pairs_weight(pairs_weight)

    cpdef _init_cat_features(self, cat_features):
        self.__pool.CatFeatures.clear()
        for feature in cat_features:
            self.__pool.CatFeatures.push_back(int(feature))

    cdef _set_data_np(self, np.float32_t [:,:] num_feature_values, object [:,:] cat_feature_values):
        if (num_feature_values is None) and (cat_feature_values is None):
            raise CatboostError('both num_feature_values and cat_feature_values are empty')

        cdef int doc_count = (
            num_feature_values.shape[0] if num_feature_values is not None else cat_feature_values.shape[0]
        )

        cdef int num_feature_count = num_feature_values.shape[1] if num_feature_values is not None else 0
        cdef int cat_feature_count = cat_feature_values.shape[1] if cat_feature_values is not None else 0

        cdef int feature_count = num_feature_count + cat_feature_count
        self.__pool.MetaInfo.FeatureCount = <ui32>feature_count

        cdef bool_t has_group_id = not self.__pool.Docs.QueryId.empty()
        cdef bool_t has_subgroup_id = not self.__pool.Docs.SubgroupId.empty()
        self.__pool.Docs.Resize(doc_count, feature_count, 0, has_group_id, has_subgroup_id)

        cdef int dst_feature_idx
        for dst_feature_idx in xrange(num_feature_count, feature_count):
            self.__pool.CatFeatures.push_back(int(dst_feature_idx))

        cdef bytes factor_bytes
        cdef TStringBuf factor_strbuf
        cdef int doc_idx
        cdef int num_feature_idx
        cdef int cat_feature_idx

        for doc_idx in range(doc_count):
            dst_feature_idx = 0
            for num_feature_idx in range(num_feature_count):
                self.__pool.Docs.Factors[dst_feature_idx][doc_idx] = num_feature_values[doc_idx, num_feature_idx]
                dst_feature_idx += 1
            for cat_feature_idx in range(cat_feature_count):
                factor_bytes = to_binary_str(cat_feature_values[doc_idx, cat_feature_idx])
                factor_strbuf = TStringBuf(<char*>factor_bytes, len(factor_bytes))
                self.__pool.SetCatFeatureHashWithBackMapUpdate(dst_feature_idx, doc_idx, factor_strbuf)
                dst_feature_idx += 1


    cdef TVector[bool_t] _get_is_cat_feature_mask(self, int feature_count):
        cdef TVector[bool_t] mask
        mask.resize(feature_count, False)

        cdef size_t idx
        for idx in range(self.__pool.CatFeatures.size()):
            mask[self.__pool.CatFeatures[idx]] = True

        return mask

    cpdef _set_data_from_generic_matrix(self, data):
        data_shape = np.shape(data)
        cdef int doc_count = data_shape[0]
        cdef int feature_count = data_shape[1]
        self.__pool.MetaInfo.FeatureCount = <ui32>feature_count

        cdef bool_t has_group_id = not self.__pool.Docs.QueryId.empty()
        cdef bool_t has_subgroup_id = not self.__pool.Docs.SubgroupId.empty()
        self.__pool.Docs.Resize(doc_count, feature_count, 0, has_group_id, has_subgroup_id)

        if doc_count == 0:
            return

        cdef object factor_bytes
        cdef TStringBuf factor_strbuf
        cdef int doc_idx
        cdef int feature_idx
        cdef int cat_feature_idx

        cdef TVector[bool_t] is_cat_feature_mask = self._get_is_cat_feature_mask(feature_count)

        for doc_idx in range(doc_count):
            doc_data = data[doc_idx]
            for feature_idx in range(feature_count):
                factor = doc_data[feature_idx]
                if is_cat_feature_mask[feature_idx]:
                    try:
                        factor_bytes = get_id_object_bytes_string_representation(factor, &factor_strbuf)
                    except CatboostError:
                        raise CatboostError(
                            'Invalid type for cat_feature[{},{}]={} :'
                            ' cat_features must be integer or string, real number values and NaN values'
                            ' should be converted to string.'.format(doc_idx, feature_idx, factor)
                        )
                    self.__pool.SetCatFeatureHashWithBackMapUpdate(feature_idx, doc_idx, factor_strbuf)
                else:
                    self.__pool.Docs.Factors[feature_idx][doc_idx] = _FloatOrNan(factor)

    cpdef _set_data_and_feature_names(self, data, feature_names):
        self.__pool.Docs.Clear()
        if isinstance(data, FeaturesData):
            self._set_data_np(data.num_feature_data, data.cat_feature_data)
            self._set_feature_names(data.get_feature_names())
        else:
            if isinstance(data, np.ndarray) and data.dtype == np.float32:
                self._set_data_np(data, None)
            else:
                self._set_data_from_generic_matrix(data)
            self._set_feature_names(feature_names)

    cpdef _set_label(self, label):
        rows = self.num_row()
        for i in range(rows):
            self.__pool.Docs.Target[i] = float(label[i])

    cpdef _set_pairs(self, pairs):
        self.__pool.Pairs.clear()
        cdef TPair* pair_ptr
        for pair in pairs:
            pair_ptr = new TPair(pair[0], pair[1], 1.)
            self.__pool.Pairs.push_back(dereference(pair_ptr))
            del pair_ptr

    cpdef _set_weight(self, weight):
        rows = self.num_row()
        for i in range(rows):
            self.__pool.Docs.Weight[i] = float(weight[i])
        self.__pool.MetaInfo.HasWeights = True
        self.__pool.MetaInfo.HasGroupWeight = False

    cpdef _set_group_id(self, group_id):
        if group_id is None:
            self.__pool.MetaInfo.HasGroupId = False
            self.__pool.Docs.QueryId.clear();
            return

        self.__pool.MetaInfo.HasGroupId = True
        rows = self.num_row()
        if rows == 0:
            return
        self.__pool.Docs.Resize(rows, self.__pool.Docs.GetEffectiveFactorCount(), self.__pool.Docs.GetBaselineDimension(), True, False)
        cdef object id_as_bytes
        cdef TStringBuf id_as_strbuf
        for i in range(rows):
            try:
                id_as_bytes = get_id_object_bytes_string_representation(group_id[i], &id_as_strbuf)
            except CatboostError:
                raise CatboostError(
                    "group_id[{}] object ({}) is unsuitable (should be string or integral type)".format(
                        i, group_id[i]
                    )
                )
            self.__pool.Docs.QueryId[i] = CalcGroupIdFor(id_as_strbuf)

    cpdef _set_group_weight(self, group_weight):
        rows = self.num_row()
        if rows == 0:
            return
        self.__pool.Docs.Resize(rows, self.__pool.Docs.GetEffectiveFactorCount(), self.__pool.Docs.GetBaselineDimension(), False, False)
        for i in range(rows):
            self.__pool.Docs.Weight[i] = float(group_weight[i])
        self.__pool.MetaInfo.HasWeights = True
        self.__pool.MetaInfo.HasGroupWeight = True

    cpdef _set_subgroup_id(self, subgroup_id):
        if subgroup_id is None:
            self.__pool.MetaInfo.HasSubgroupIds = False
            self.__pool.Docs.SubgroupId.clear();
            return

        self.__pool.MetaInfo.HasSubgroupIds = True
        rows = self.num_row()
        if rows == 0:
            return
        self.__pool.Docs.Resize(rows, self.__pool.Docs.GetEffectiveFactorCount(), self.__pool.Docs.GetBaselineDimension(), False, True)
        cdef object id_as_bytes
        cdef TStringBuf id_as_strbuf
        for i in range(rows):
            try:
                id_as_bytes = get_id_object_bytes_string_representation(subgroup_id[i], &id_as_strbuf)
            except CatboostError:
                raise CatboostError(
                    "subgroup_id[{}] object ({}) is unsuitable (should be string or integral type)".format(
                        i, subgroup_id[i]
                    )
                )
            self.__pool.Docs.SubgroupId[i] = CalcSubgroupIdFor(id_as_strbuf)

    cpdef _set_pairs_weight(self, pairs_weight):
        rows = self.num_pairs()
        for i in range(rows):
            self.__pool.Pairs[i].Weight = float(pairs_weight[i])

    cpdef _set_baseline(self, baseline):
        self.__pool.MetaInfo.BaselineCount = len(baseline[0])

        rows = self.num_row()
        if rows == 0:
            return
        self.__pool.Docs.Resize(
            rows,
            self.__pool.Docs.GetEffectiveFactorCount(),
            self.__pool.MetaInfo.BaselineCount,
            False,
            False
        )

        for i in range(rows):
            for j, value in enumerate(baseline[i]):
                self.__pool.Docs.Baseline[j][i] = float(value)

    cpdef _set_feature_names(self, feature_names):
        self.__pool.FeatureId.clear()
        if feature_names is None:
            # init to empty strings
            self.__pool.FeatureId.resize(self.__pool.Docs.GetEffectiveFactorCount())
        else:
            # consistency of sizes for self.__pool.Docs.GetEffectiveFactorCount() and feature_names
            # has been already checked
            for value in feature_names:
                value = to_binary_str(str(value))
                self.__pool.FeatureId.push_back(value)

    cpdef get_feature_names(self):
        feature_names = []
        cdef bytes pystr
        for value in self.__pool.FeatureId:
            pystr = value.c_str()
            feature_names.append(to_native_str(pystr))
        return feature_names

    cpdef num_row(self):
        """
        Get the number of rows in the Pool.

        Returns
        -------
        number of rows : int
        """
        return self.__pool.Docs.GetDocCount()

    cpdef num_col(self):
        """
        Get the number of columns in the Pool.

        Returns
        -------
        number of cols : int
        """
        return self.__pool.Docs.GetEffectiveFactorCount()

    cpdef num_pairs(self):
        """
        Get the number of pairs in the Pool.

        Returns
        -------
        number of pairs : int
        """
        return self.__pool.Pairs.size()

    @property
    def shape(self):
        """
        Get the shape of the Pool.

        Returns
        -------
        shape : (int, int)
            (rows, cols)
        """
        return tuple([self.num_row(), self.num_col()])

    cpdef get_features(self):
        """
        Get feature matrix from Pool.

        Returns
        -------
        feature matrix : list(list)
        """
        data = []
        for doc in range(self.__pool.Docs.GetDocCount()):
            factors = []
            for factor in self.__pool.Docs.Factors:
                factors.append(factor[doc])
            data.append(factors)
        return data

    cpdef get_label(self):
        """
        Get labels from Pool.

        Returns
        -------
        labels : list
        """
        if self.has_label_:
            return [target for target in self.__pool.Docs.Target]
        return None

    cpdef get_cat_feature_indices(self):
        """
        Get cat_feature indices from Pool.

        Returns
        -------
        cat_feature_indices : list
        """
        return [self.__pool.CatFeatures.at(i) for i in range(self.__pool.CatFeatures.size())]

    cpdef get_cat_feature_hash_to_string(self):
        """
        Get maping of float hash values to corresponding strings

        Returns
        -------
        hash_to_string : map
        """
        hash_to_string = {}
        for factor_hash, factor_string in self.__pool.CatFeaturesHashToString:
            hash_to_string[ConvertCatFeatureHashToFloat(factor_hash)] = factor_string
        return hash_to_string

    cpdef get_weight(self):
        """
        Get weight for each instance.

        Returns
        -------
        weight : list
        """
        return [weight for weight in self.__pool.Docs.Weight]

    cpdef get_baseline(self):
        """
        Get baseline from Pool.

        Returns
        -------
        baseline : list(list)
        """
        baseline = []
        for doc in range(self.__pool.Docs.GetDocCount()):
            doc_approxes = []
            for approx in self.__pool.Docs.Baseline:
                doc_approxes.append(approx[doc])
            baseline.append(doc_approxes)
        return baseline

    cpdef _take_slice(self, _PoolBase pool, row_indices):
        cdef TVector[size_t] rowIndices
        for index in row_indices:
            rowIndices.push_back(index)
        cdef TPool* slicedPool = SlicePool(dereference(pool.__pool), rowIndices).Release()
        del self.__pool
        self.__pool = slicedPool
        self.has_label_ = pool.has_label_

    @property
    def is_empty_(self):
        """
        Check if Pool is empty (contains no objects).

        Returns
        -------
        is_empty_ : bool
        """
        return self.__pool.Docs.GetDocCount() == 0


cdef class _CatBoost:
    cdef TFullModel* __model
    cdef TVector[TEvalResult*] __test_evals

    def __cinit__(self):
        self.__model = new TFullModel()

    def __dealloc__(self):
        del self.__model
        for i in range(self.__test_evals.size()):
            del self.__test_evals[i]

    cpdef _reserve_test_evals(self, num_tests):
        if self.__test_evals.size() < num_tests:
            self.__test_evals.resize(num_tests)
        for i in range(num_tests):
            if self.__test_evals[i] == NULL:
                self.__test_evals[i] = new TEvalResult()

    cpdef _clear_test_evals(self):
        for i in range(self.__test_evals.size()):
            dereference(self.__test_evals[i]).ClearRawValues()

    cpdef _train(self, _PoolBase train_pool, test_pools, dict params, allow_clear_pool):
        prep_params = _PreprocessParams(params)
        cdef int thread_count = params.get("thread_count", 1)
        cdef TClearablePoolPtrs clearablePoolPtrs
        clearablePoolPtrs.Learn = train_pool.__pool
        clearablePoolPtrs.AllowClearLearn = allow_clear_pool
        cdef _PoolBase test_pool
        if isinstance(test_pools, list):
            if params.get('task_type', 'CPU') == 'GPU' and len(test_pools) > 1:
                raise CatboostError('Multiple eval sets are not supported on GPU')
            for test_pool in test_pools:
                clearablePoolPtrs.Test.push_back(test_pool.__pool)
        else:
            test_pool = test_pools
            clearablePoolPtrs.Test.push_back(test_pool.__pool)
        self._reserve_test_evals(clearablePoolPtrs.Test.size())
        self._clear_test_evals()

        with nogil:
            SetPythonInterruptHandler()
            try:
                TrainModel(
                    prep_params.tree,
                    prep_params.customObjectiveDescriptor,
                    prep_params.customMetricDescriptor,
                    clearablePoolPtrs,
                    TString(<const char*>""),
                    self.__model,
                    self.__test_evals
                )
            finally:
                ResetPythonInterruptHandler()

    cpdef _set_test_evals(self, test_evals):
        cdef TVector[double] vector
        num_tests = len(test_evals)
        self._reserve_test_evals(num_tests)
        self._clear_test_evals()
        for test_no in range(num_tests):
            for row in test_evals[test_no]:
                for value in row:
                    vector.push_back(float(value))
                dereference(self.__test_evals[test_no]).GetRawValuesRef()[0].push_back(vector)
                vector.clear()

    cpdef _get_test_evals(self):
        test_evals = []
        num_tests = self.__test_evals.size()
        for test_no in range(num_tests):
            test_eval = []
            for i in range(self.__test_evals[test_no].GetRawValuesRef()[0].size()):
                test_eval.append([value for value in dereference(self.__test_evals[test_no]).GetRawValuesRef()[0][i]])
            test_evals.append(test_eval)
        return test_evals

    cpdef _has_leaf_weights_in_model(self):
        return not self.__model.ObliviousTrees.LeafWeights.empty()

    cpdef _get_cat_feature_indices(self):
        return [feature.FlatFeatureIndex for feature in self.__model.ObliviousTrees.CatFeatures]

    cpdef _get_float_feature_indices(self):
            return [feature.FlatFeatureIndex for feature in self.__model.ObliviousTrees.FloatFeatures]

    cpdef _base_predict(self, _PoolBase pool, str prediction_type, int ntree_start, int ntree_end, int thread_count, verbose):
        cdef TVector[double] pred
        cdef EPredictionType predictionType = PyPredictionType(prediction_type).predictionType
        thread_count = UpdateThreadCount(thread_count);

        pred = ApplyModel(
            dereference(self.__model),
            dereference(pool.__pool),
            verbose,
            predictionType,
            ntree_start,
            ntree_end,
            thread_count
        )
        return [value for value in pred]

    cpdef _base_predict_multi(self, _PoolBase pool, str prediction_type, int ntree_start, int ntree_end,
                              int thread_count, verbose):
        cdef TVector[TVector[double]] pred
        cdef EPredictionType predictionType = PyPredictionType(prediction_type).predictionType
        thread_count = UpdateThreadCount(thread_count);

        pred = ApplyModelMulti(
            dereference(self.__model),
            dereference(pool.__pool),
            verbose,
            predictionType,
            ntree_start,
            ntree_end,
            thread_count
        )
        return _convert_to_visible_labels(prediction_type, pred, thread_count, self.__model)

    cpdef _staged_predict_iterator(self, _PoolBase pool, str prediction_type, int ntree_start, int ntree_end, int eval_period, int thread_count, verbose):
        thread_count = UpdateThreadCount(thread_count);
        stagedPredictIterator = _StagedPredictIterator(pool, prediction_type, ntree_start, ntree_end, eval_period, thread_count, verbose)
        stagedPredictIterator.set_model(self.__model)
        return stagedPredictIterator

    cpdef _base_eval_metrics(self, _PoolBase pool, metric_descriptions, int ntree_start, int ntree_end, int eval_period, int thread_count, result_dir, tmp_dir):
        result_dir = to_binary_str(result_dir)
        tmp_dir = to_binary_str(tmp_dir)
        thread_count = UpdateThreadCount(thread_count);
        cdef TVector[TString] metricDescriptions
        for metric_description in metric_descriptions:
            metric_description = to_binary_str(metric_description)
            metricDescriptions.push_back(TString(<const char*>metric_description))

        cdef TVector[TVector[double]] metrics
        metrics = EvalMetrics(
            dereference(self.__model),
            dereference(pool.__pool),
            metricDescriptions,
            ntree_start,
            ntree_end,
            eval_period,
            thread_count,
            TString(<const char*>result_dir),
            TString(<const char*>tmp_dir)
        )
        cdef TVector[TString] metric_names = GetMetricNames(dereference(self.__model), metricDescriptions)
        return metrics, [to_native_str(name) for name in metric_names]

    cpdef _calc_fstr(self, fstr_type_name, _PoolBase pool, int thread_count, int verbose):
        fstr_type_name = to_binary_str(fstr_type_name)
        thread_count = UpdateThreadCount(thread_count);
        cdef TVector[TString] feature_ids = GetMaybeGeneratedModelFeatureIds(
            dereference(self.__model),
            pool.__pool if pool else NULL,
        )

        cdef TVector[TVector[double]] fstr
        cdef TVector[TVector[TVector[double]]] fstr_multi

        if fstr_type_name == 'ShapValues' and dereference(self.__model).ObliviousTrees.ApproxDimension > 1:
            fstr_multi = GetFeatureImportancesMulti(
                TString(<const char*>fstr_type_name),
                dereference(self.__model),
                pool.__pool if pool else NULL,
                thread_count,
                verbose
            )
            return [
                       [
                           [value for value in fstr_multi[i][j]] for j in range(fstr_multi[i].size())
                       ] for i in range(fstr_multi.size())
                   ], feature_ids
        else:
            fstr = GetFeatureImportances(
                TString(<const char*>fstr_type_name),
                dereference(self.__model),
                pool.__pool if pool else NULL,
                thread_count,
                verbose
            )
            return [[value for value in fstr[i]] for i in range(fstr.size())], feature_ids

    cpdef _calc_ostr(self, _PoolBase train_pool, _PoolBase test_pool, int top_size, ostr_type, update_method, importance_values_sign, int thread_count):
        ostr_type = to_binary_str(ostr_type)
        update_method = to_binary_str(update_method)
        importance_values_sign = to_binary_str(importance_values_sign)
        thread_count = UpdateThreadCount(thread_count);
        cdef TDStrResult ostr = GetDocumentImportances(
            dereference(self.__model),
            dereference(train_pool.__pool),
            dereference(test_pool.__pool),
            TString(<const char*>ostr_type),
            top_size,
            TString(<const char*>update_method),
            TString(<const char*>importance_values_sign),
            thread_count
        )
        indices = [[int(value) for value in ostr.Indices[i]] for i in range(ostr.Indices.size())]
        scores = [[value for value in ostr.Scores[i]] for i in range(ostr.Scores.size())]
        if ostr_type == to_binary_str('Average'):
            indices = indices[0]
            scores = scores[0]
        return indices, scores

    cpdef _base_shrink(self, int ntree_start, int ntree_end):
        self.__model.ObliviousTrees.Truncate(ntree_start, ntree_end)

    cpdef _load_model(self, model_file, format):
        cdef TFullModel tmp_model
        model_file = to_binary_str(model_file)
        cdef EModelType modelType = PyModelType(format).modelType
        tmp_model = ReadModel(TString(<const char*>model_file), modelType)
        self.__model.Swap(tmp_model)

    cpdef _save_model(self, output_file, format, export_parameters, _PoolBase pool):
        cdef EModelType modelType = PyModelType(format).modelType
        export_parameters = to_binary_str(export_parameters)
        output_file = to_binary_str(output_file)
        ExportModel(
            dereference(self.__model),
            output_file,
            modelType,
            export_parameters,
            False,
            &(dereference(pool.__pool).FeatureId) if pool else NULL,
            &(dereference(pool.__pool).CatFeaturesHashToString) if pool else NULL
        )

    cpdef _serialize_model(self):
        cdef TString tstr = SerializeModel(dereference(self.__model))
        cdef const char* c_serialized_model_string = tstr.c_str()
        cpdef bytes py_serialized_model_str = c_serialized_model_string[:tstr.size()]
        return py_serialized_model_str

    cpdef _deserialize_model(self, TString serialized_model_str):
        cdef TFullModel tmp_model
        tmp_model = DeserializeModel(serialized_model_str);
        self.__model.Swap(tmp_model)

    cpdef _get_params(self):
        if not self.__model.ModelInfo.has("params"):
            return {}
        cdef const char* c_params_json = self.__model.ModelInfo["params"].c_str()
        cdef bytes py_params_json = c_params_json
        params_json = to_native_str(py_params_json)
        params = {}
        if params_json:
            for key, value in loads(params_json)["flat_params"].iteritems():
                if key != 'random_seed':
                    params[str(key)] = value
        return params

    def _get_tree_count(self):
        return self.__model.GetTreeCount()

    def _get_random_seed(self):
        if not self.__model.ModelInfo.has("params"):
            return {}
        cdef const char* c_params_json = self.__model.ModelInfo["params"].c_str()
        cdef bytes py_params_json = c_params_json
        params_json = to_native_str(py_params_json)
        if params_json:
            return loads(params_json).get('random_seed', 0)
        return 0

    def _get_learning_rate(self):
        if not self.__model.ModelInfo.has("params"):
            return {}
        cdef const char* c_params_json = self.__model.ModelInfo["params"].c_str()
        cdef bytes py_params_json = c_params_json
        params_json = to_native_str(py_params_json)
        if params_json:
            params = loads(params_json)
            if 'boosting_options' in params:
                return params['boosting_options'].get('learning_rate', None)
        return None

    def _get_metadata_wrapper(self):
        return _MetadataHashProxy(self)

    def _get_feature_names(self):
        return GetModelUsedFeaturesNames(dereference(self.__model))


cdef class _MetadataHashProxy:
    cdef _CatBoost _catboost
    def __init__(self, catboost):
        self._catboost = catboost  # here we store reference to _Catboost class to increment object ref count

    def __getitem__(self, key):
        if not isinstance(key, string_types):
            raise CatboostError('only string keys allowed')
        key = to_binary_str(key)
        if not self._catboost.__model.ModelInfo.has(key):
            raise KeyError
        return to_native_str(self._catboost.__model.ModelInfo.at(key))

    def get(self, key, default=None):
        try:
            return self[key]
        except KeyError:
            return default

    def __setitem__(self, key, value):
        if not isinstance(key, string_types):
            raise CatboostError('only string keys allowed')
        if not isinstance(value, string_types):
            raise CatboostError('only string values allowed')
        key = to_binary_str(key)
        self._catboost.__model.ModelInfo[key] = to_binary_str(value)

    def __delitem__(self, key):
        if not isinstance(key, string_types):
            raise CatboostError('only string keys allowed')
        key = to_binary_str(key)
        if not self._catboost.__model.ModelInfo.has(key):
            raise KeyError
        self._catboost.__model.ModelInfo.erase(TString(<const char*>key))

    def __len__(self):
        return self._catboost.__model.ModelInfo.size()

    def keys(self):
        return [to_native_str(kv.first) for kv in self._catboost.__model.ModelInfo]

    def iterkeys(self):
        return (to_native_str(kv.first) for kv in self._catboost.__model.ModelInfo)

    def __iter__(self):
        return self.iterkeys()

    def items(self):
        return [(to_native_str(kv.first), to_native_str(kv.second)) for kv in self._catboost.__model.ModelInfo]

    def iteritems(self):
        return ((to_native_str(kv.first), to_native_str(kv.second)) for kv in self._catboost.__model.ModelInfo)


cpdef _cv(dict params, _PoolBase pool, int fold_count, bool_t inverted, int partition_random_seed,
          bool_t shuffle, bool_t stratified, bool_t as_pandas):
    prep_params = _PreprocessParams(params)
    cdef TCrossValidationParams cvParams
    cdef TVector[TCVResult] results

    cvParams.FoldCount = fold_count
    cvParams.PartitionRandSeed = partition_random_seed
    cvParams.Shuffle = shuffle
    cvParams.Stratified = stratified
    cvParams.Inverted = inverted

    with nogil:
        SetPythonInterruptHandler()
        try:
            CrossValidate(
                prep_params.tree,
                prep_params.customObjectiveDescriptor,
                prep_params.customMetricDescriptor,
                dereference(pool.__pool),
                cvParams,
                &results)
        finally:
            ResetPythonInterruptHandler()

    result = defaultdict(list)
    metric_count = results.size()
    used_metric_names = set()
    for metric_idx in xrange(metric_count):
        metric_name = to_native_str(results[metric_idx].Metric.c_str())
        if metric_name in used_metric_names:
            continue
        used_metric_names.add(metric_name)
        for it in xrange(results[metric_idx].AverageTrain.size()):
            result["test-" + metric_name + "-mean"].append(results[metric_idx].AverageTest[it])
            result["test-" + metric_name + "-std"].append(results[metric_idx].StdDevTest[it])
            result["train-" + metric_name + "-mean"].append(results[metric_idx].AverageTrain[it])
            result["train-" + metric_name + "-std"].append(results[metric_idx].StdDevTrain[it])

    if as_pandas:
        try:
            from pandas import DataFrame
            return DataFrame.from_dict(result)
        except ImportError:
            pass
    return result


cdef _FloatOrStringFromString(char* s):
    cdef char* stop = NULL
    cdef double parsed = StrToD(s, &stop)
    cdef float res
    if len(s) == 0:
        return s
    elif stop == s + len(s):
        return float(parsed)
    return s


cdef  _convert_to_visible_labels(str prediction_type, TVector[TVector[double]] raws, int thread_count, TFullModel* model):
     if prediction_type == 'Class':
        return [[_FloatOrStringFromString(value) for value \
            in ConvertTargetToExternalName([value for value in raws[0]], dereference(model))]]

     return [[value for value in vec] for vec in raws]


cdef class _StagedPredictIterator:
    cdef TVector[TVector[double]] __approx
    cdef TFullModel* __model
    cdef _PoolBase pool
    cdef str prediction_type
    cdef int ntree_start, ntree_end, eval_period, thread_count
    cdef bool_t verbose

    cdef set_model(self, TFullModel* model):
        self.__model = model

    def __cinit__(self, _PoolBase pool, str prediction_type, int ntree_start, int ntree_end, int eval_period, int thread_count, verbose):
        self.pool = pool
        self.prediction_type = prediction_type
        self.ntree_start = ntree_start
        self.ntree_end = ntree_end
        self.eval_period = eval_period
        self.thread_count = thread_count
        self.verbose = verbose

    def __dealloc__(self):
        pass

    def __deepcopy__(self, _):
        raise CatboostError('Can\'t deepcopy _StagedPredictIterator object')

    def next(self):
        if self.ntree_start >= self.ntree_end:
            raise StopIteration

        cdef TVector[TVector[double]] pred
        cdef EPredictionType predictionType = PyPredictionType(self.prediction_type).predictionType
        pred = ApplyModelMulti(dereference(self.__model),
                               dereference(self.pool.__pool),
                               self.verbose,
                               PyPredictionType('InternalRawFormulaVal').predictionType,
                               self.ntree_start,
                               min(self.ntree_start + self.eval_period, self.ntree_end),
                               self.thread_count)
        if self.__approx.empty():
            self.__approx = pred
        else:
            for i in range(self.__approx.size()):
                for j in range(self.__approx[0].size()):
                    self.__approx[i][j] += pred[i][j]

        self.ntree_start += self.eval_period
        pred = PrepareEvalForInternalApprox(predictionType, dereference(self.__model), self.__approx, 1)

        return  _convert_to_visible_labels(self.prediction_type, pred, self.thread_count, self.__model)



class MetricDescription:

    def __init__(self, metric_name, is_max_optimal):
        self._metric_description = metric_name
        self._is_max_optimal = is_max_optimal

    def get_metric_description(self):
        return self._metric_description

    def is_max_optimal(self):
        return self._is_max_optimal

    def __str__(self):
        return self._metric_description

    def __repr__(self):
        return self.__str__()

    def __eq__(self, other):
        return self._metric_description == other._metric_description and self._is_max_optimal == other._is_max_optimal

    def __hash__(self):
        return hash((self._metric_description, self._is_max_optimal))


def _metric_description_or_str_to_str(metric_description):
    key = None
    if isinstance(metric_description, MetricDescription):
        key = metric_description.get_metric_description()
    else:
        key = metric_description
    return key

class EvalMetricsResult:

    def __init__(self, plots, metrics_description):
        self._plots = dict()
        self._metric_descriptions = dict()

        for (plot, metric) in zip(plots, metrics_description):
            key = _metric_description_or_str_to_str(metric)
            self._metric_descriptions[key] = metrics_description
            self._plots[key] = plot


    def has_metric(self, metric_description):
        key = _metric_description_or_str_to_str(metric_description)
        return key in self._metric_descriptions

    def get_metric(self, metric_description):
        key = _metric_description_or_str_to_str(metric_description)
        return self._metric_descriptions[metric_description]

    def get_result(self, metric_description):
        key = _metric_description_or_str_to_str(metric_description)
        return self._plots[key]


cdef class _MetricCalcerBase:
    cdef TMetricsPlotCalcerPythonWrapper*__calcer
    cdef _CatBoost __catboost

    cpdef _create_calcer(self, metrics_description, int ntree_start, int ntree_end, int eval_period, int thread_count,
                         tmp_dir, bool_t delete_temp_dir_on_exit):
        thread_count=UpdateThreadCount(thread_count);
        cdef TVector[TString] metricsDescription
        for metric_description in metrics_description:
            metric_description = to_binary_str(metric_description)
            metricsDescription.push_back(TString(<const char*> metric_description))

        tmp_dir = to_binary_str(tmp_dir)
        self.__calcer = new TMetricsPlotCalcerPythonWrapper(metricsDescription, dereference(self.__catboost.__model),
                                                            ntree_start, ntree_end, eval_period, thread_count,
                                                            TString(<const char*> tmp_dir), delete_temp_dir_on_exit)

        self._metric_descriptions = list()

        cdef TVector[const IMetric*] metrics = self.__calcer.GetMetricRawPtrs()

        for metric_idx in xrange(metrics.size()):
            metric = metrics[metric_idx]
            name = to_native_str(metric.GetDescription().c_str())
            flag = IsMaxOptimal(dereference(metric))
            self._metric_descriptions.append(MetricDescription(name, flag))

    def __init__(self, catboost_model, *args, **kwargs):
        self.__catboost = catboost_model
        self._metric_descriptions = list()

    def __dealloc__(self):
        del self.__calcer

    def metric_descriptions(self):
        return self._metric_descriptions

    def eval_metrics(self):
        cdef TVector[TVector[double]] plots = self.__calcer.ComputeScores()
        return EvalMetricsResult([[value for value in plot] for plot in plots],
                                 self._metric_descriptions)

    cpdef add(self, _PoolBase pool):
        self.__calcer.AddPool(dereference(pool.__pool))

    def __deepcopy__(self):
        raise CatboostError('Can\'t deepcopy _MetricCalcerBase object')

cpdef _eval_metric_util(label_param, approx_param, metric, weight_param, group_id_param, thread_count):
    if (len(label_param) != len(approx_param[0])):
        raise CatboostError('Label and approx should have same sizes.')
    doc_count = len(label_param);

    cdef TVector[float] label
    label.resize(doc_count)
    for i in range(doc_count):
        label[i] = float(label_param[i])

    approx_dimention = len(approx_param)
    cdef TVector[TVector[double]] approx
    approx.resize(approx_dimention)
    for i in range(approx_dimention):
        approx[i].resize(doc_count)
        for j in range(doc_count):
            approx[i][j] = float(approx_param[i][j])

    cdef TVector[float] weight
    if weight_param is not None:
        if (len(weight_param) != doc_count):
            raise CatboostError('Label and weight should have same sizes.')
        weight.resize(doc_count)
        for i in range(doc_count):
            weight[i] = float(weight_param[i])

    cdef TStringBuf group_id_strbuf
    cdef object group_id_bytes

    cdef TVector[TGroupId] group_id;
    if group_id_param is not None:
        if (len(group_id_param) != doc_count):
            raise CatboostError('Label and group_id should have same sizes.')
        group_id.resize(doc_count)
        for i in range(doc_count):
            group_id_bytes = get_id_object_bytes_string_representation(group_id_param[i], &group_id_strbuf)
            group_id[i] = CalcGroupIdFor(group_id_strbuf)

    metric = to_binary_str(metric)
    thread_count = UpdateThreadCount(thread_count);

    return EvalMetricsForUtils(label, approx, TString(<const char*> metric), weight, group_id, thread_count)

cpdef _get_roc_curve(model, pools_list, thread_count):
    thread_count = UpdateThreadCount(thread_count)
    cdef TVector[TPool] pools
    for pool in pools_list:
        pools.push_back(dereference((<_PoolBase>pool).__pool))
    cdef TVector[TRocPoint] curve = TRocCurve(
        dereference((<_CatBoost>model).__model), pools, thread_count
    ).GetCurvePoints()
    tpr = np.array([1 - point.FalseNegativeRate for point in curve])
    fpr = np.array([point.FalsePositiveRate for point in curve])
    thresholds = np.array([point.Boundary for point in curve])
    return fpr, tpr, thresholds

cpdef _select_threshold(model, data, curve, FPR, FNR, thread_count):
    if FPR is not None and FNR is not None:
        raise CatboostError('Only one of the parameters FPR, FNR should be initialized.')

    thread_count = UpdateThreadCount(thread_count)

    cdef TRocCurve rocCurve
    cdef TVector[TRocPoint] points
    cdef TVector[TPool] pools

    if data is not None:
        for pool in data:
            pools.push_back(dereference((<_PoolBase>pool).__pool))
        rocCurve = TRocCurve(dereference((<_CatBoost>model).__model), pools, thread_count)
    else:
        size = len(curve[2])
        for i in range(size):
            points.push_back(TRocPoint(curve[2][i], 1 - curve[1][i], curve[0][i]))
        rocCurve = TRocCurve(points)

    if FPR is not None:
        return rocCurve.SelectDecisionBoundaryByFalsePositiveRate(FPR)
    if FNR is not None:
        return rocCurve.SelectDecisionBoundaryByFalseNegativeRate(FNR)
    return rocCurve.SelectDecisionBoundaryByIntersection()

log_cout = None
log_cerr = None

cdef void _CoutLogPrinter(const char* str, size_t len) except * with gil:
    cdef bytes bytes_str = str[:len]
    log_cout.write(to_native_str(bytes_str))

cdef void _CerrLogPrinter(const char* str, size_t len) except * with gil:
    cdef bytes bytes_str = str[:len]
    log_cerr.write(to_native_str(bytes_str))

cpdef _set_logger(cout, cerr):
    global log_cout
    global log_cerr
    log_cout = cout
    log_cerr = cerr
    SetCustomLoggingFunction(&_CoutLogPrinter, &_CerrLogPrinter)

cpdef _reset_logger():
    RestoreOriginalLogger()

cpdef _configure_malloc():
    ConfigureMalloc()

cpdef _library_init():
    LibraryInit()

cpdef compute_wx_test(baseline, test):
    cdef TVector[double] baselineVec
    cdef TVector[double] testVec
    for x in baseline:
        baselineVec.push_back(x)
    for x in test:
        testVec.push_back(x)
    result=WxTest(baselineVec, testVec)
    return {"pvalue" : result.PValue, "wplus":result.WPlus, "wminus":result.WMinus}

cpdef is_classification_loss(loss_name):
    loss_name = to_binary_str(loss_name)
    return IsClassificationLoss(TString(<const char*> loss_name))

cpdef _check_train_params(dict params):
    params_to_check = params.copy()
    if 'cat_features' in params_to_check:
        del params_to_check['cat_features']

    prep_params = _PreprocessParams(params_to_check)
    CheckFitParams(
        prep_params.tree,
        prep_params.customObjectiveDescriptor.Get(),
        prep_params.customMetricDescriptor.Get())

cpdef _get_gpu_device_count():
    return GetGpuDeviceCount()
