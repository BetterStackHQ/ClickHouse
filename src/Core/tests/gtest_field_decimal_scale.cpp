#include <gtest/gtest.h>

#include <Common/Exception.h>
#include <Common/FieldBinaryEncoding.h>
#include <Core/DecimalFunctions.h>
#include <Core/Field.h>
#include <Core/SettingsFields.h>
#include <IO/ReadBufferFromString.h>
#include <IO/WriteBufferFromString.h>
#include <IO/WriteHelpers.h>

#include <limits>

using namespace DB;

namespace DB::ErrorCodes
{
    extern const int ARGUMENT_OUT_OF_BOUND;
}

namespace
{

template <typename T>
class FieldDecimalScale : public ::testing::Test
{
};

using DecimalTypes = ::testing::Types<Decimal32, Decimal64, Decimal128, Decimal256>;
TYPED_TEST_SUITE(FieldDecimalScale, DecimalTypes);

template <typename T>
UInt8 compactTag()
{
    if constexpr (std::is_same_v<T, Decimal32>)
        return 0x08;
    else if constexpr (std::is_same_v<T, Decimal64>)
        return 0x09;
    else if constexpr (std::is_same_v<T, Decimal128>)
        return 0x0a;
    else
        return 0x0b;
}

template <typename T>
String decimalDump(Int32 exponent, Int32 value = 1)
{
    return "Decimal" + std::to_string(sizeof(T) * 8) + "_'" + std::to_string(value) + "e" + std::to_string(exponent) + "'";
}

template <typename T>
String binaryDecimal(UInt32 scale, bool compact, Int32 value = 1)
{
    WriteBufferFromOwnString out;
    if (compact)
    {
        writeBinary(compactTag<T>(), out);
        writeVarUInt(scale, out);
        writeBinaryLittleEndian(T(value), out);
    }
    else
    {
        writeBinary(static_cast<UInt8>(Field(DecimalField<T>(T(1), 0)).getType()), out);
        writeBinary(T(value), out);
        writeBinary(scale, out);
    }
    return out.str();
}

template <typename F>
void expectInvalidScale(F && read)
{
    try
    {
        read();
        FAIL() << "An invalid decimal scale was accepted";
    }
    catch (const Exception & e)
    {
        EXPECT_EQ(e.code(), ErrorCodes::ARGUMENT_OUT_OF_BOUND);
        EXPECT_NE(e.message().find("is out of bounds (max scale:"), String::npos);
    }
}

TYPED_TEST(FieldDecimalScale, BinaryBoundaries)
{
    constexpr UInt32 max_scale = DecimalUtils::max_precision<TypeParam>;
    for (bool compact : {false, true})
    {
        SCOPED_TRACE(compact);
        for (UInt32 scale : {UInt32(0), UInt32(1), max_scale})
        {
            SCOPED_TRACE(scale);
            for (Int32 value : {-1, 0, 1})
            {
                String bytes = binaryDecimal<TypeParam>(scale, compact, value);
                ReadBufferFromString in(bytes);
                Field field = compact ? decodeField(in) : readFieldBinary(in);
                ASSERT_TRUE(in.eof());
                const auto & decimal = field.template safeGet<DecimalField<TypeParam>>();
                EXPECT_EQ(decimal.getScale(), scale);
                EXPECT_EQ(decimal.getValue(), TypeParam(value));
                WriteBufferFromOwnString out;
                if (compact)
                    encodeField(field, out);
                else
                    writeFieldBinary(field, out);
                EXPECT_EQ(out.str(), bytes);
            }
        }
        for (UInt32 scale : {max_scale + 1, UInt32(77), UInt32(78), UInt32(0x80000000), std::numeric_limits<UInt32>::max()})
        {
            SCOPED_TRACE(scale);
            String bytes = binaryDecimal<TypeParam>(scale, compact);
            ReadBufferFromString in(bytes);
            expectInvalidScale([&] { return compact ? decodeField(in) : readFieldBinary(in); });
        }
    }
}

TYPED_TEST(FieldDecimalScale, TextBoundaries)
{
    constexpr Int32 max_scale = DecimalUtils::max_precision<TypeParam>;
    for (Int32 scale : {0, 1, max_scale})
    {
        SCOPED_TRACE(scale);
        for (Int32 value : {-1, 0, 1})
        {
            Field field = Field::restoreFromDump(decimalDump<TypeParam>(-scale, value));
            const auto & decimal = field.template safeGet<DecimalField<TypeParam>>();
            EXPECT_EQ(decimal.getScale(), static_cast<UInt32>(scale));
            EXPECT_EQ(decimal.getValue(), TypeParam(value));
        }
    }
    for (Int32 scale : {max_scale + 1, 77, 78})
    {
        SCOPED_TRACE(scale);
        expectInvalidScale([&] { return Field::restoreFromDump(decimalDump<TypeParam>(-scale)); });
    }
    Field positive = Field::restoreFromDump(decimalDump<TypeParam>(1));
    EXPECT_EQ(positive.template safeGet<DecimalField<TypeParam>>().getValue(), TypeParam(10));
    EXPECT_EQ(positive.template safeGet<DecimalField<TypeParam>>().getScale(), 0);
}

TYPED_TEST(FieldDecimalScale, NestedBinaryValues)
{
    constexpr UInt32 invalid_scale = DecimalUtils::max_precision<TypeParam> + 1;
    for (bool compact : {false, true})
    {
        for (auto type : {Field::Types::Array, Field::Types::Tuple, Field::Types::Object})
        {
            WriteBufferFromOwnString out;
            if (compact)
            {
                writeBinary(UInt8(type == Field::Types::Array ? 0x0d : type == Field::Types::Tuple ? 0x0e : 0x14), out);
                writeVarUInt(1, out);
            }
            else
            {
                writeBinary(static_cast<UInt8>(type), out);
                writeBinary(size_t(1), out);
            }
            String child = binaryDecimal<TypeParam>(invalid_scale, compact);
            if (type == Field::Types::Object)
            {
                if (!compact)
                {
                    writeBinary(static_cast<UInt8>(child[0]), out);
                    child.erase(0, 1);
                }
                writeStringBinary("key", out);
            }
            out.write(child.data(), child.size());
            String bytes = out.str();
            ReadBufferFromString in(bytes);
            expectInvalidScale([&] { return compact ? decodeField(in) : readFieldBinary(in); });
        }
    }
}

TYPED_TEST(FieldDecimalScale, CompactBudgetAndEarlyRejection)
{
    constexpr UInt32 max_scale = DecimalUtils::max_precision<TypeParam>;
    String bytes = binaryDecimal<TypeParam>(max_scale, true);
    ReadBufferFromString in(bytes);
    size_t complexity = 0;
    Field field = decodeField(in, complexity, 1);
    EXPECT_EQ(complexity, 1);
    EXPECT_EQ(field.template safeGet<DecimalField<TypeParam>>().getScale(), max_scale);

    bytes = binaryDecimal<TypeParam>(max_scale + 1, true);
    bytes.resize(bytes.size() - sizeof(TypeParam));
    ReadBufferFromString invalid(bytes);
    complexity = 0;
    expectInvalidScale([&] { return decodeField(invalid, complexity, 1); });
}

TYPED_TEST(FieldDecimalScale, TruncatedScale)
{
    for (bool compact : {false, true})
    {
        String bytes = binaryDecimal<TypeParam>(1, compact);
        if (compact)
        {
            bytes.resize(2);
            bytes[1] = static_cast<char>(0x80);
        }
        else
            bytes.pop_back();
        ReadBufferFromString in(bytes);
        try
        {
            if (compact)
                decodeField(in);
            else
                readFieldBinary(in);
            FAIL() << "A truncated decimal scale was accepted";
        }
        catch (const Exception & e)
        {
            EXPECT_NE(e.code(), ErrorCodes::ARGUMENT_OUT_OF_BOUND);
        }
    }
}

TYPED_TEST(FieldDecimalScale, CustomSettingRejectsInvalidDump)
{
    SettingFieldCustom setting;
    expectInvalidScale([&] { setting.parseFromString(decimalDump<TypeParam>(-Int32(DecimalUtils::max_precision<TypeParam> + 1))); });
}

}
